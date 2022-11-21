// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

module turbos::vault {
    use sui::math;
    use std::vector;
    use sui::transfer;
    use sui::object::{Self, UID};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance, Supply};
    use sui::tx_context::{Self, TxContext};
    use sui::vec_map::{Self, VecMap};


    /// Coin<TLP> is the token used to mark the liquidity pool share.
    struct TLP has drop { }

    struct Positions has key, store {
        id: UID,
        position_data: VecMap<PositionId, Position>,
        collateral: u64,
        size: u64,
    }

    struct PositionId has store, copy, drop {
        collateral_token: address,
        index_token: address,
        is_long: bool,
    }
    struct Position has store {
        id: UID,
        size: u64,
        collateral: u64,
        average_price: u64,
        entry_funding_rate: u64,
        realised_pnl: u64 ,
        last_increased_time: u64,
    }

    struct Vault has key, store {
        id: UID,
        tlp_supply: Supply<TLP>,
        aum_addition: u64,
        aum_deduction: u64,

        is_swap_enabled: bool,
        whitelisted_token_count: u8,
        // default: 50 * 10000 50x
        max_leverage: u8, 

        /// fees
        liquidation_fee_usd: u8,
        // default: 50 | 0.5%
        tax_basis_points: u8,
        // default: 20 | 0.3%
        stable_tax_basis_points: u8,
        // default: 30 | 0.3%
        mint_burn_fee_basis_points: u8,
        // default: 30 | 0.3%
        swap_fee_basis_points: u8,
        // default: 4 | 0.04%
        stable_swap_fee_basis_points: u8,
        // default: 10 | 0.1%
        margin_fee_basis_points: u8,

        min_profit_time: u64,
        // default: false
        has_dynamic_fees: bool,

        ///funding
        // default: 8 hours
        funding_interval: u64,
        funding_rate_factor: u64,
        stable_funding_rate_factor: u64,
        total_token_weights: u64,

        ///token
        all_whitelisted_tokens: vector<address>,
        white_listed_tokens: VecMap<address, bool>,
        token_decimals: VecMap<address, u8>,
        min_profit_basis_points: VecMap<address, u8>,
        stable_tokens: VecMap<address, bool>,
        shortable_tokens: VecMap<address, bool>,

        // tokenWeights allows customisation of index composition
        token_weights: VecMap<address, u64>, 
        // usdgAmounts tracks the amount of USDG debt for each whitelisted token
        usdg_amounts: VecMap<address, u64>,
        // maxUsdgAmounts allows setting a max amount of USDG debt for a token
        max_usdg_amounts: VecMap<address, u64>,
        // poolAmounts tracks the number of received tokens that can be used for leverage
        // this is tracked separately from tokenBalances to exclude funds that are deposited as margin collateral
        pool_amounts: VecMap<address, u64>,
        // reservedAmounts tracks the number of tokens reserved for open leverage positions
        reserved_amounts: VecMap<address, u64>,
        // bufferAmounts allows specification of an amount to exclude from swaps
        // this can be used to ensure a certain amount of liquidity is available for leverage positions
        buffer_amounts: VecMap<address, u64>,
        // guaranteedUsd tracks the amount of USD that is "guaranteed" by opened leverage positions
        // this value is used to calculate the redemption values for selling of USDG
        // this is an estimated amount, it is possible for the actual guaranteed value to be lower
        // in the case of sudden price decreases, the guaranteed value should be corrected
        // after liquidations are carried out
        guaranteed_usd: VecMap<address, u64>,

        // cumulativeFundingRates tracks the funding rates based on utilization
        cumulative_funding_rates: VecMap<address, u64>,
        // lastFundingTimes tracks the last time funding was updated for a token
        last_funding_times: VecMap<address, u64>,
        // feeReserves tracks the amount of fees per token
        fee_reserves: VecMap<address, u64>,
        global_short_sizes: VecMap<address, u64>,
        global_short_average_prices: VecMap<address, u64>,
        max_global_short_sizes: VecMap<address, u64>,
    }

    struct Pool<T> has key {
        id: UID,
        token: Balance<T>,
    }

    fun init(_: &mut TxContext) {}

    public fun create_pool(witness: TLP, ctx: &mut TxContext) {
        let tlp_supply = balance::create_supply<TLP>(witness);

        let vault = Vault {
            id: object::new(ctx),
            tlp_supply,
            is_swap_enabled: false,
            aum_addition: 0,
            aum_deduction: 0, 
            whitelisted_token_count: 0,
            max_leverage: 50, 
            liquidation_fee_usd: 2, //todo 2usd
            tax_basis_points: 50,
            stable_tax_basis_points: 30,
            mint_burn_fee_basis_points: 30,
            swap_fee_basis_points: 30,
            stable_swap_fee_basis_points: 4,
            margin_fee_basis_points: 10,
            min_profit_time: 0,
            has_dynamic_fees: false,
            funding_interval: 28800,
            funding_rate_factor: 100,
            stable_funding_rate_factor: 100,
            total_token_weights: 0,
            all_whitelisted_tokens: vector::empty(),
            white_listed_tokens: vec_map::empty(),
            token_decimals: vec_map::empty(),
            min_profit_basis_points: vec_map::empty(),
            stable_tokens: vec_map::empty(),
            shortable_tokens: vec_map::empty(),
            token_weights: vec_map::empty(),
            usdg_amounts: vec_map::empty(),
            max_usdg_amounts: vec_map::empty(),
            pool_amounts: vec_map::empty(),
            reserved_amounts: vec_map::empty(),
            buffer_amounts: vec_map::empty(),
            guaranteed_usd: vec_map::empty(),
            cumulative_funding_rates: vec_map::empty(),
            last_funding_times: vec_map::empty(),
            fee_reserves: vec_map::empty(),
            global_short_sizes: vec_map::empty(),
            global_short_average_prices: vec_map::empty(),
            max_global_short_sizes: vec_map::empty()
        };
        transfer::share_object(vault);
    }

    public fun add_liquidity<T>(vault: &mut Vault, pool: &mut Pool<T>, token: Coin<T>, ctx: &mut TxContext): Coin<TLP> {
        // 1. calcalate AUM
        let aum = get_aum(vault, object::id_address(&token));
        // 2. get glp supply
        // 3. calculate gpl amount
        // transfer token to valut
        // mint glp to user
        let tok_balance = coin::into_balance(token);
        let tok_amt = balance::join(&mut pool.token, tok_balance);
        let balance = balance::increase_supply(&mut vault.tlp_supply, 100);
        //let token_amount = coin::value(&token);
        coin::from_balance(balance, ctx)
    }

    fun get_aum(vault: &mut Vault, token: address): u64 {
        let len = vector::length(&vault.all_whitelisted_tokens);
        let aum = *&vault.aum_addition;
        let aum_deduction = *&vault.aum_deduction;
        let short_profits = 0;
        let i = 0;
        while (i < len) {
            i = i + 1;
            let is_whitelisted = *vec_map::get(&vault.white_listed_tokens,&token);
            if (is_whitelisted) {
                continue
            };
            // todo: get price from oracle
            let price = 1;

            let pool_amount = *vec_map::get(&vault.pool_amounts,&token);
            let decimals = *vec_map::get(&vault.token_decimals,&token);

            if (*vec_map::get(&vault.stable_tokens,&token)) {
                aum = aum + (pool_amount * price / math::pow(10, decimals));
            } else {
                let size = *vec_map::get(&vault.global_short_sizes,&token);
                if (size > 0) {
                    let (delta, has_profit) = get_global_short_delta(vault, token, price, size);
                    if (!has_profit) {
                        // add losses from shorts
                        aum = aum + delta;
                    } else {
                        short_profits = short_profits + delta;
                    };
                };

                let guaranteed_usd = *vec_map::get(&vault.guaranteed_usd,&token);
                aum = aum + guaranteed_usd;

                let reserved_amount = *vec_map::get(&vault.reserved_amounts,&token);
                aum = aum + ((pool_amount - reserved_amount) * price / math::pow(10, decimals));
            };
        };

        aum = if (short_profits > aum) 0 else (aum - short_profits);
        aum = if (aum_deduction > aum) 0 else (aum - aum_deduction);
        aum
    }

    fun get_global_short_delta(vault: &mut Vault, token: address, price: u64, size: u64): (u64, bool) {
        // todo: get price from short tracker 
        let average_price  = *vec_map::get(&vault.global_short_average_prices,&token);
        let priceDelta = if (average_price > price) average_price - price else price - average_price;
        let delta = size * priceDelta / average_price;
        (delta, average_price > price)
    }

    public fun is_swap_enabled(vault: &mut Vault,): bool {
        vault.is_swap_enabled
    }

}