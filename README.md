# W5500 Optimized Linux Driver

Optimized Linux kernel driver for the WIZnet W5500 Ethernet controller over SPI,
targeting **Raspberry Pi Zero 2W** with Raspberry Pi OS (kernel 6.12+).

Measured improvement over the stock driver: **+25% throughput, −20s on 100MB download** on an external network (RTT ~286ms).

---

## Changes from the Original Kernel Driver

### 1. Batch RX — single SPI transaction per interrupt

**Original**: called `w5100_rx()` once per packet, each call doing a separate SPI read.

**Optimized**: `w5100_rx_batch()` reads all available RX data from the W5500 in **one SPI transaction**, then parses every packet from CPU memory (`rx_buf`).

```c
/* ORIGINAL — one SPI read per packet, called repeatedly */
static int w5100_rx(struct net_device *ndev)
{
    u16 rx_len = w5100_read16(priv, W5100_S0_RX_RSR(priv));
    /* ... read one packet via SPI ... */
    /* ... update RX_RD, send RECV ... */
}

/* OPTIMIZED — all available data in one SPI read */
static int w5100_rx_batch(struct net_device *ndev, int budget, bool napi)
{
    u16 new_len = w5100_read16(priv, W5100_S0_RX_RSR(priv)); /* up to 16KB */

    w5100_readbuf(priv, offset, priv->rx_buf + priv->rx_partial, new_len);

    priv->rx_rd = offset + new_len;
    w5100_write16(priv, W5100_S0_RX_RD(priv), priv->rx_rd);
    w5100_command(priv, S0_CR_RECV);

    /* parse all packets from rx_buf in CPU memory — no more SPI */
    while (ptr + 2 <= end && rx_count < budget) {
        /* ... alloc skb, memcpy, netif_rx ... */
    }
}
```

---

### 2. RX_RD Local Cache

**Original**: read `RX_RD` register from W5500 over SPI on every call.

**Optimized**: cache the value in `priv->rx_rd`. It is always known after each update.

```c
/* ORIGINAL — SPI read every time */
u32 offset = w5100_read16(priv, W5100_S0_RX_RD(priv));

/* OPTIMIZED — local cache, no SPI */
u32 offset = priv->rx_rd;  /* updated in-place after each batch */
```

Added to `struct w5100_priv`:

```c
u8  *rx_buf;       /* batch RX buffer (2 × s0_rx_buf_size = 32KB) */
u16  rx_partial;   /* leftover bytes from previous batch (partial packet) */
u16  rx_rd;        /* cached RX_RD register value — eliminates SPI read */
```

---

### 3. Early `w5100_enable_intr` — eliminates inter-batch scheduling gap

**Original**: re-enable the W5500 interrupt after packet processing completes.
The next interrupt can only fire after `enable_intr`, then the workqueue
takes ~1ms to schedule the next SPI read.

**Optimized**: re-enable the interrupt **immediately after the SPI read and `S0_CR_RECV`**,
before the packet processing loop. Packet parsing uses only CPU memory (no SPI),
so the W5500 interrupt can fire during parsing and pre-queue the next job.
By the time parsing finishes, the next SPI read starts with zero scheduling gap.

```c
/* ORIGINAL */
static void w5100_rx_work(struct work_struct *work)
{
    while (w5100_rx_batch(priv->ndev, INT_MAX, false) > 0)
        ;
    w5100_enable_intr(priv);  /* <-- interrupt re-enabled AFTER processing */
}

/* OPTIMIZED — inside w5100_rx_batch, after SPI read */
    w5100_readbuf(priv, offset, priv->rx_buf + priv->rx_partial, new_len);

    priv->rx_rd = offset + new_len;
    w5100_write16(priv, W5100_S0_RX_RD(priv), priv->rx_rd);
    w5100_command(priv, S0_CR_RECV);

    w5100_enable_intr(priv);  /* <-- interrupt re-enabled HERE, before while loop */

    while (ptr + 2 <= end && rx_count < budget) {
        /* ... packet processing ... */
        /* next IRQ fires here → queue_work pre-queued → zero gap after loop */
    }
```

Timeline comparison:

```
Before:  [SPI 5.24ms] → [process 0.5ms] → enable_intr → [sched gap 1ms] → [SPI 5.24ms]
After:   [SPI 5.24ms] → enable_intr → [process 0.5ms] → [SPI 5.24ms]
                                            ^ IRQ fires, next work pre-queued
```

---

### 4. rx_partial Bug Fix — removed incorrect cap on read length

**Original**: when `rx_partial > 0`, the next read was capped to prevent overflowing the old-sized buffer:

```c
/* ORIGINAL — limits new_len, leaves data in W5500 hardware buffer */
if (new_len > priv->s0_rx_buf_size - priv->rx_partial)
    new_len = priv->s0_rx_buf_size - priv->rx_partial;
```

If `rx_partial = 2KB` and `new_len = 16KB`, only `14KB` would be read,
leaving 2KB in the W5500 buffer unnecessarily.

**Fixed**: `rx_buf` is allocated at `2 × s0_rx_buf_size` (32KB), so
`rx_partial` (up to 16KB) + `new_len` (up to 16KB) always fits safely.
The cap is removed entirely.

```c
/* OPTIMIZED — rx_buf is 32KB, always read full new_len */
priv->rx_buf = kmalloc(priv->s0_rx_buf_size * 2, GFP_KERNEL);

/* cap removed — new_len always read in full */
w5100_readbuf(priv, offset, priv->rx_buf + priv->rx_partial, new_len);
```

---

### 5. DEBUG / Non-DEBUG Build

```makefile
make DEBUG=0   # default — replaces stock w5100 / w5100_spi modules
make DEBUG=1   # debug  — builds w5100_debug / w5100_spi_debug (separate from stock)
```

| `DEBUG` | Module name | `compatible` string |
|---|---|---|
| `0` | `w5100`, `w5100_spi` | `wiznet,w5500` |
| `1` | `w5100_debug`, `w5100_spi_debug` | `wiznet,w5500_debug` |

`DEBUG=0` is compatible with the stock `dtoverlay=w5500` — no DTS change required.

---

## Installation

### Requirements

- Raspberry Pi Zero 2W running Raspberry Pi OS (kernel 6.12+)
- Internet connection
- W5500 wired to SPI0 and configured in `/boot/firmware/config.txt` (see below)

### Install

```bash
wget https://raw.githubusercontent.com/seok930927/W5500_Driver/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

The script will:
1. Install build dependencies (`git`, `make`, `gcc`, kernel headers)
2. Clone this repository to a temporary directory (auto-cleaned on exit)
3. Build the driver with `DEBUG=0`
4. Back up the stock `.ko.xz` files to `.ko.xz.bak`
5. Install the new `.ko` files and run `depmod -a`
6. Prompt to reboot

### Revert to Stock Driver

```bash
sudo ./install.sh -Remove
```

Restores the original `.ko.xz` files from `.ko.xz.bak` and runs `depmod -a`.

---

## Device Tree Configuration

Add to `/boot/firmware/config.txt`:

```ini
dtoverlay=w5500,int_pin=25,speed=25000000
```

| Parameter | Description | Default |
|---|---|---|
| `int_pin` | GPIO pin number for W5500 INTn | `25` |
| `speed` | SPI clock in Hz (max stable: 25MHz) | `20000000` |
| `cs` | SPI chip select (0 = CE0, 1 = CE1) | `0` |

### Wiring (SPI0, CE0)

| W5500 | Raspberry Pi Pin | GPIO |
|---|---|---|
| SCLK | 23 | GPIO11 |
| MOSI | 19 | GPIO10 |
| MISO | 21 | GPIO9 |
| CSn  | 24 | GPIO8 (CE0) |
| INTn | 22 | GPIO25 (default) |

### Full DTS Example

The following is the complete overlay used by this driver (`source/w5500-overlay.dts`):

```dts
/dts-v1/;
/plugin/;

/ {
    compatible = "brcm,bcm2835";

    /* Disable default spidev on CE0 */
    fragment@0 {
        target = <&spidev0>;
        __overlay__ {
            status = "disabled";
        };
    };

    /* Register W5500 on SPI0 CE0 */
    fragment@2 {
        target = <&spi0>;
        __overlay__ {
            #address-cells = <1>;
            #size-cells = <0>;
            status = "okay";

            eth1: w5500@0 {
                compatible = "wiznet,w5500";   /* matches DEBUG=0 driver */
                reg = <0>;                     /* CE0 */
                pinctrl-names = "default";
                pinctrl-0 = <&eth1_pins>;
                interrupt-parent = <&gpio>;
                interrupts = <25 0x8>;         /* GPIO25, active-low */
                spi-max-frequency = <25000000>; /* 25MHz */
                status = "okay";
            };
        };
    };

    /* Configure interrupt GPIO as input, no pull */
    fragment@3 {
        target = <&gpio>;
        __overlay__ {
            eth1_pins: eth1_pins {
                brcm,pins = <25>;
                brcm,function = <0>; /* input */
                brcm,pull = <0>;     /* none */
            };
        };
    };

    /* Runtime overrides: dtoverlay=w5500,int_pin=X,speed=Y */
    __overrides__ {
        int_pin = <&eth1>,      "interrupts:0",
                  <&eth1_pins>, "brcm,pins:0";
        speed   = <&eth1>,      "spi-max-frequency:0";
        cs      = <&eth1>,      "reg:0",
                  <0>,          "!0=1";
    };
};
```

To use `DEBUG=1`, change `compatible` to `"wiznet,w5500_debug"` and use `dtoverlay=w5500-debug`.
