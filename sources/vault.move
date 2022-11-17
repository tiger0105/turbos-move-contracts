// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

module turbos::vault {
    use std::vector;
    use sui::transfer;
    use sui::object::{Self, UID};
    use sui::table::{Self, Table};
    use sui::tx_context::{Self, TxContext};

    struct Positions has key, store {
        position_data: Table<PositionId, Position>,
        collateral: u64,
        size: u64,
    }

    struct PositionId has store, copy, drop {
        collateral_token: address,
        index_token: address,
        is_long: bool,
    }
    struct Position has store {
        size: u64,
        collateral: u64,
        average_price: u64,
        entry_funding_rate: u64,
        realised_pnl: u64 ,
        last_increased_time: u64,
    }

    struct Vault has key, store {
        is_swap_enabled: bool,
        whitelistedTokenCount: u8,
        // default: 50 * 10000 50x
        maxLeverage: u8, 

        /// fees
        liquidationFeeUsd: u8,
        // default: 50 | 0.5%
        taxBasisPoints: u8,
        // default: 20 | 0.3%
        stableTaxBasisPoints: u8,
        // default: 30 | 0.3%
        mintBurnFeeBasisPoints: u8,
        // default: 30 | 0.3%
        swapFeeBasisPoints: u8,
        // default: 4 | 0.04%
        stableSwapFeeBasisPoints: u8,
        // default: 10 | 0.1%
        marginFeeBasisPoints: u8,

        minProfitTime: u64,
        // default: false
        hasDynamicFees: bool,

        ///funding
        // default: 8 hours
        fundingInterval: u64,
        fundingRateFactor: u64,
        stableFundingRateFactor: u64,
        total_token_weights: u64,

        ///token
        allWhitelistedTokens: vector<address>,
        tokenDecimals: Table<address, u8>,
        minProfitBasisPoints: Table<address, u8>,
        stableTokens: Table<address, bool>,
        shortableTokens: Table<address, bool>,

        // tokenBalances is used only to determine _transferIn values
        tokenDecimals: Table<address, 64>, 
        // tokenWeights allows customisation of index composition
        tokenWeights: Table<address, 64>, 
        // usdgAmounts tracks the amount of USDG debt for each whitelisted token
        usdgAmounts: Table<address, 64>,
        // maxUsdgAmounts allows setting a max amount of USDG debt for a token
        maxUsdgAmounts: Table<address, 64>,
        // poolAmounts tracks the number of received tokens that can be used for leverage
        // this is tracked separately from tokenBalances to exclude funds that are deposited as margin collateral
        poolAmounts: Table<address, 64>,
        // reservedAmounts tracks the number of tokens reserved for open leverage positions
        reservedAmounts: Table<address, 64>,
        // bufferAmounts allows specification of an amount to exclude from swaps
        // this can be used to ensure a certain amount of liquidity is available for leverage positions
        bufferAmounts: Table<address, 64>,
        // guaranteedUsd tracks the amount of USD that is "guaranteed" by opened leverage positions
        // this value is used to calculate the redemption values for selling of USDG
        // this is an estimated amount, it is possible for the actual guaranteed value to be lower
        // in the case of sudden price decreases, the guaranteed value should be corrected
        // after liquidations are carried out
        guaranteedUsd: Table<address, 64>,

        // cumulativeFundingRates tracks the funding rates based on utilization
        cumulativeFundingRates: Table<address, 64>,
        // lastFundingTimes tracks the last time funding was updated for a token
        lastFundingTimes: Table<address, 64>,
        // feeReserves tracks the amount of fees per token
        feeReserves: Table<address, 64>,
        globalShortSizes: Table<address, 64>,
        globalShortAveragePrices: Table<address, 64>,
        maxGlobalShortSizes: Table<address, 64>,
    }

    public entry fun init(ctx: &mut TxContext) {
        /// initialize
    }

    public fun owner(counter: &Counter): address {
        counter.owner
    }

    public fun value(counter: &Counter): u64 {
        counter.value
    }


    public entry fun swap(ctx: &mut TxContext) {
    }
}