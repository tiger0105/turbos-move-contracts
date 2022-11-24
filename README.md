# turbos-move-contracts

The Sui move contracts of turbos perpetual protocol.

## Overview

Turbos makes full use of all the power provided by Sui to create a decentralized perpetual exchange that is simple enough for everyone, ​​empowering the full circulation of assets in the Sui ecosystem. Users only need to open crypto positions and leave the rest to smart contracts.

## Quick start

### build

```
sui move build
```

### public

```
sui client publish --path . --gas-budget 3000
```

### config

```
// set fees
sui client call --function set_fees --module vault --package 0xa4b65f2e617f566bca8f0be33ff36192c0c011a9 --args 0xc05314ecf13ad13ef7223e1b8d24316b7a719547 0x4be71224d1d02899482a27e55a02738b63a9e711 10 5 20 20 1 10 2000000000 86400  true  --gas-budget 1000

// set funding fee
sui client call --function set_funding_rate --module vault --package 0xa4b65f2e617f566bca8f0be33ff36192c0c011a9 --args  0xc05314ecf13ad13ef7223e1b8d24316b7a719547 0x4be71224d1d02899482a27e55a02738b63a9e711 3600 100 100 --gas-budget 1000
```
