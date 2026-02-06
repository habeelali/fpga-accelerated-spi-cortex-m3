## 1. SPI Link Layer (Electrical + Timing)

### 1.1 Roles
- **MCU**: SPI master
- **FPGA**: SPI slave

### 1.2 Mode / Framing
- **SPI mode**: Mode 0 (CPOL=0, CPHA=0)
- **Bit order**: MSB-first
- **Word size**: 8 bits

### 1.3 Chip Select (CS) Behavior
- CS low = exactly one command transaction
- SPI command parser resets on CS rising edge (end of transaction)
- Any partial command is discarded on CS rising edge

### 1.4 Clock Rate
- **SPI SCLK target**: 2 MHz

### 1.5 FPGA Internal Clock
- **FPGA system clock**: 27 MHz
- **Requirement**: internal clock must be comfortably higher than SPI SCLK to sample and process bytes reliably (implementation detail)

---

## 2. SPI Transaction Layer (Register Protocol)

This project uses a **SPI register protocol (Option A)**.

### 2.1 Addressing
- Register addresses are byte addresses aligned to 32-bit words: `0x00`, `0x04`, `0x08`, ...
- On the wire, transmit a register index: `REG_IDX = (ADDR >> 2)`

### 2.2 Command Byte Encoding
One command per CS-low transaction.

- **CMD[7]** = RW bit
  - `1` = write
  - `0` = read
- **CMD[6:0]** = REG_IDX (7-bit index)

**So:**
- Write: `CMD = 0x80 | REG_IDX`
- Read: `CMD = 0x00 | REG_IDX`

### 2.3 Data Width and Endianness
- **Register data**: 32-bit
- **On-wire byte order for 32-bit data**: little-endian
  - DATA0 = bits [7:0]
  - DATA1 = bits [15:8]
  - DATA2 = bits [23:16]
  - DATA3 = bits [31:24]

### 2.4 Write Transaction
**CS low:**
- MOSI: `[CMD][DATA0][DATA1][DATA2][DATA3]`
- MISO: don't care

**CS high:** command ends, parser resets

The FPGA applies the write on receipt of the 4th data byte.

### 2.5 Read Transaction (1-byte turnaround)
**CS low:**
- MOSI: `[CMD][DUMMY][DUMMY][DUMMY][DUMMY]`
- MISO: `[DUMMY][DATA0][DATA1][DATA2][DATA3]`

**CS high:** command ends, parser resets

- The first MISO byte after CMD is undefined/dummy (turnaround)
- The next 4 MISO bytes are the 32-bit register value (little-endian)

### 2.6 Invalid/Incomplete Transactions
- If CS rises before 5 bytes total (CMD + 4), FPGA discards the command
- If an unknown `REG_IDX` is accessed:
  - Reads return `0x00000000`
  - Writes are ignored

---

## 3. Register Map + Semantics

All registers are 32-bit.

### 3.1 STATUS (0x00) — Read-only, sticky flags
**Reset value:** `0x00000000`

**Bits:**
- `bit0` **RX_READY**: 1 if RX_COUNT > 0
- `bit1` **PKT_OK**: sticky; set when a full packet passes CRC and is committed to RX FIFO
- `bit2` **CRC_ERR**: sticky; set when a packet fails CRC check (packet dropped)
- `bit3` **RX_OVF**: sticky; set if RX FIFO overflows (see overflow policy)
- `bit4` **BAD_CMD**: sticky; set if a malformed SPI transaction is detected (optional; can be stubbed early)

**Clear behavior:**
- Sticky bits clear when `CTRL.CLEAR_FLAGS` is strobed

**Notes**:
- BAD_CMD is set when an SPI transaction violates the register protocol (e.g., RX_DATA read when RX_COUNT=0, or incomplete command terminated early by CS).
- RX_READY is combinational and reflects RX_COUNT > 0; it is not sticky and does not require clearing.

### 3.2 RX_COUNT (0x04) — Read-only
**Reset value:** `0x00000000`

- Bits [15:0]: number of bytes currently stored in RX FIFO (0..DEPTH)
- Remaining bits read as 0

### 3.3 TX_COUNT (0x08) — Read-only
**Reset value:** implementation-defined (typically FIFO depth)

- Bits [15:0]: number of free byte slots available in TX FIFO (0..DEPTH)
- Remaining bits read as 0

### 3.4 CTRL (0x0C) — Read/write control
**Reset value:** `0x00000000`

**Bits:**
- `bit0` **CLEAR_FLAGS**: self-clearing strobe; writing 1 clears sticky flags in STATUS
- `bit1` **RX_FLUSH**: self-clearing strobe; flush RX FIFO (drops all RX bytes)
- `bit2` **TX_FLUSH**: self-clearing strobe; flush TX FIFO (drops queued TX bytes)
- `bit3` **IRQ_EN**: optional; 0=disabled, 1=enabled (can be stubbed until later)
- `bit4` **SOFT_RESET**: optional; self-clearing strobe; resets packet parser + CRC state

**Notes:**
- For strobe bits, writing 1 triggers the action; bit reads back as 0

### 3.5 RX_DATA (0x10) — Read-only, pop-on-read byte FIFO
**Reset value:** undefined

- Bits [7:0] return next byte from RX FIFO
- Reading RX_DATA pops one byte if RX_COUNT > 0
- If RX_COUNT == 0, RX_DATA returns `0x00` and sets BAD_CMD (optional)

### 3.6 TX_DATA (0x14) — Write-only, push-on-write byte FIFO
- Writing bits [7:0] pushes one byte into TX FIFO
- If TX FIFO is full, the byte is dropped and (optionally) a sticky flag may be added later (e.g., TX_OVF)

### 3.7 RX_TYPE (0x18) — Read-only (recommended)
**Reset value:** `0x00000000`

- Bits [7:0] hold the TYPE field of the most recently accepted packet (PKT_OK)
- Useful because RX FIFO will contain payload only (see Packet section)
- If you want to keep the register count minimal, RX_TYPE may be omitted and TYPE can be packed into STATUS bits [15:8] later

---

## 4. Packet Format + CRC Rules

Packets are validated by FPGA and delivered to firmware via RX FIFO.

### 4.1 Packet Layout (byte stream)
```
[SOF][LEN][TYPE][PAYLOAD...][CRC_L][CRC_H]
```

**Definitions:**
- **SOF**: start-of-frame marker (1 byte)
- **LEN**: payload length in bytes (1 byte, 0..255)
- **TYPE**: message type (1 byte)
- **PAYLOAD**: LEN bytes
- **CRC_L, CRC_H**: CRC16 result, little-endian (low byte then high byte)

### 4.2 Fixed Constants
- **SOF** = `0xA5`

### 4.3 CRC Parameters (frozen)
- **CRC algorithm**: CRC-16/CCITT-FALSE
- **Polynomial**: `0x1021`
- **Init**: `0xFFFF`
- **Reflect in**: false
- **Reflect out**: false
- **XorOut**: `0x0000`

### 4.4 CRC Coverage
CRC is computed over:
```
[LEN][TYPE][PAYLOAD...]
```
SOF is **not** included.

### 4.5 Accept/Drop Rules
- On receiving SOF, FPGA resets packet parser and CRC state
- FPGA reads LEN and TYPE, then consumes LEN payload bytes
- FPGA reads 2 CRC bytes and compares:
  - **If match:**
    - PKT_OK flag set (sticky)
    - RX_TYPE updated with TYPE (if implemented)
    - Only PAYLOAD bytes are written into RX FIFO (payload-only contract)
  - **If mismatch:**
    - CRC_ERR flag set (sticky)
    - Packet is dropped (no payload committed)

### 4.6 RX FIFO Contract (payload-only)
- RX FIFO contains exactly PAYLOAD bytes for accepted packets
- Firmware gets packet boundary using one of:
  - fixed-length payloads per TYPE during bring-up, or
  - later addition of RX_LEN / RX_META register (recommended later)

### 4.7 Overflow Policy
If RX FIFO does not have space for all LEN bytes at commit time:
- drop the packet
- set RX_OVF sticky
- do not partially commit payload
