// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

module turbos::vault {
    use sui::math;
    use sui::event;
    use std::vector;
    use sui::transfer;
    use sui::object::{Self, UID};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance, Supply};
    use sui::tx_context::{Self, TxContext};
    use sui::vec_map::{Self, VecMap};

    /** errors */
    const EInsufficientTusdOutput: u64 = 0;
	const EInsufficientTlpOutput: u64 = 1;
    const ETokenNotWhiteListed: u64 = 2;
    const EInvalidAmountIn: u64 =3;
    const EInvalidAmountOut: u64 =4;
    const EInvalidTusdAmount: u64 = 5;
    /** errors end*/

    const PRICE_PRECISION: u64 = 100000000;
    const GLP_PRECISION: u64 = 1000000000000000000;
    const TUSD_DECIMALS: u8 = 18;
    const TUSD_ADDRESS: address = @0x1;
    const BASIS_POINTS_DIVISOR: u64 = 10000;

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
        tusd_supply_amount: u64,
        aum_addition: u64,
        aum_deduction: u64,

        is_swap_enabled: bool,
        whitelisted_token_count: u64,
        // default: 50 * 10000 50x
        max_leverage: u64, 

        /// fees
        liquidation_fee_usd: u64,
        // default: 50 | 0.5%
        tax_basis_points: u64,
        // default: 20 | 0.3%
        stable_tax_basis_points: u64,
        // default: 30 | 0.3%
        mint_burn_fee_basis_points: u64,
        // default: 30 | 0.3%
        swap_fee_basis_points: u64,
        // default: 4 | 0.04%
        stable_swap_fee_basis_points: u64,
        // default: 10 | 0.1%
        margin_fee_basis_points: u64,

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
        min_profit_basis_points: VecMap<address, u64>,
        stable_tokens: VecMap<address, bool>,
        shortable_tokens: VecMap<address, bool>,

        // tokenWeights allows customisation of index composition
        token_weights: VecMap<address, u64>, 
        // tusdAmounts tracks the amount of USDG debt for each whitelisted token
        tusd_amounts: VecMap<address, u64>,
        // maxUsdgAmounts allows setting a max amount of USDG debt for a token
        max_tusd_amounts: VecMap<address, u64>,
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
        last_liquidity_added_at: VecMap<address, u64>,
    }

    struct Pool<phantom T> has key {
        id: UID,
        token: Balance<T>,
    }

    struct BuyTUSDEvent has copy, drop {
        receiver: address,
        token: address,
        token_amount: u64,
        mint_amount: u64,
        fee_basis_points: u64,
    }

    struct CollectSwapFeesEvent has copy, drop {
        token: address,
        fee_in_usd: u64,
        fee_token_amount: u64,
    }
    
    struct UpdateFundingRateEvent has copy, drop {
        collateral_token: address,
        cumulative_funding_rates: u64,
    }

    struct AddLiquidityEvent has copy, drop {
        account: address, 
        token: address, 
        amount: u64,
        aum_in_tusd: u64, 
        tlp_supply: u64,
        tusd_amount: u64, 
        mint_amount: u64,
    }

    struct IncreaseTusdAmountEvent has copy, drop {
        token: address, 
        amount: u64,
    }

    struct IncreasePoolAmountEvent has copy, drop {
        token: address, 
        amount: u64,
    }

    fun init(_: &mut TxContext) {}

    public fun create_vault(witness: TLP, ctx: &mut TxContext) {
        let tlp_supply = balance::create_supply<TLP>(witness);

        let vault = Vault {
            id: object::new(ctx),
            tlp_supply,
            tusd_supply_amount: 0,
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
            tusd_amounts: vec_map::empty(),
            max_tusd_amounts: vec_map::empty(),
            pool_amounts: vec_map::empty(),
            reserved_amounts: vec_map::empty(),
            buffer_amounts: vec_map::empty(),
            guaranteed_usd: vec_map::empty(),
            cumulative_funding_rates: vec_map::empty(),
            last_funding_times: vec_map::empty(),
            fee_reserves: vec_map::empty(),
            global_short_sizes: vec_map::empty(),
            global_short_average_prices: vec_map::empty(),
            max_global_short_sizes: vec_map::empty(),
            last_liquidity_added_at: vec_map::empty(),
        };
        transfer::share_object(vault);
    }

    entry fun add_liquidity<T>(vault: &mut Vault, pool: &mut Pool<T>, token: Coin<T>, min_tusd: u64, min_tlp: u64, ctx: &mut TxContext) {
        transfer::transfer(
            add_liquidity_(vault, pool, token, min_tusd, min_tlp, ctx),
            tx_context::sender(ctx)
        );
    }

    fun add_liquidity_<T>(vault: &mut Vault, pool: &mut Pool<T>, token: Coin<T>, min_tusd: u64, min_tlp: u64, ctx: &mut TxContext):  Coin<TLP> {
        // calcalate AUM
        let aum_in_tusd = get_aum_in_tusd(vault, true);
        let tlp_supply = balance::supply_value(&vault.tlp_supply);

        let token_address = object::id_address(&token);
        let token_balance = coin::into_balance(token);
        let token_amount = balance::value(&token_balance);
        assert!(token_amount > 0, EInvalidAmountIn);
		balance::join(&mut pool.token, token_balance);

		// buy tusd from vault
		let tusd_amount = buy_tusd(vault, token_address, token_amount, ctx);
		assert!(tusd_amount > min_tusd, EInsufficientTusdOutput);

		let mint_amount = if(aum_in_tusd == 0) tusd_amount else tusd_amount * tlp_supply / aum_in_tusd;
		assert!(mint_amount > min_tlp, EInsufficientTlpOutput);

        // increase glp supply
        let balance = balance::increase_supply(&mut vault.tlp_supply, mint_amount);

        let last_liquidity_added_at = vec_map::get_mut(&mut vault.last_liquidity_added_at, &token_address);
        *last_liquidity_added_at = *last_liquidity_added_at + tx_context::epoch(ctx);
        event::emit(AddLiquidityEvent { account: tx_context::sender(ctx), token: token_address, amount: token_amount, aum_in_tusd, tlp_supply, tusd_amount, mint_amount });

        coin::from_balance(balance, ctx)
    }

	fun get_aum_in_tusd(vault: &mut Vault, maximise: bool): u64 {
        let aum = get_aum(vault, maximise);
        aum * math::pow(10 , TUSD_DECIMALS) / PRICE_PRECISION
    }

    fun get_aum(vault: &mut Vault, maximise: bool): u64 {
        let len = vector::length(&vault.all_whitelisted_tokens);
        let aum = vault.aum_addition;
        let aum_deduction = vault.aum_deduction;
        let short_profits = 0;
        let i = 0;
        while (i < len) {
            i = i + 1;
            let token = *vector::borrow(&vault.all_whitelisted_tokens, i);
            let is_whitelisted = *vec_map::get(&vault.white_listed_tokens, &token);
            if (is_whitelisted) {
                continue
            };

            let price = if (maximise) get_max_price(vault, token) else get_min_price(vault, token);
            let pool_amount = *vec_map::get(&vault.pool_amounts, &token);
            let decimals = *vec_map::get(&vault.token_decimals, &token);

            if (*vec_map::get(&vault.stable_tokens, &token)) {
                aum = aum + (pool_amount * price / math::pow(10, decimals));
            } else {
                let size = *vec_map::get(&vault.global_short_sizes, &token);
                if (size > 0) {
                    let (delta, has_profit) = get_global_short_delta(vault, token, price, size);
                    if (!has_profit) {
                        // add losses from shorts
                        aum = aum + delta;
                    } else {
                        short_profits = short_profits + delta;
                    };
                };

                let guaranteed_usd = *vec_map::get(&vault.guaranteed_usd, &token);
                aum = aum + guaranteed_usd;

                let reserved_amount = *vec_map::get(&vault.reserved_amounts, &token);
                aum = aum + ((pool_amount - reserved_amount) * price / math::pow(10, decimals));
            };
        };

        aum = if (short_profits > aum) 0 else (aum - short_profits);
        aum = if (aum_deduction > aum) 0 else (aum - aum_deduction);
        aum
    }

    fun get_global_short_delta(vault: &mut Vault, token: address, price: u64, size: u64): (u64, bool) {
        // todo: get price from short tracker 
        let average_price  = *vec_map::get(&vault.global_short_average_prices, &token);
        let priceDelta = if (average_price > price) average_price - price else price - average_price;
        let delta = size * priceDelta / average_price;
        (delta, average_price > price)
    }

    fun buy_tusd(vault: &mut Vault, token: address, token_amount: u64, ctx: &mut TxContext): u64 {
        assert!(*vec_map::get(&vault.white_listed_tokens, &token), ETokenNotWhiteListed);
        assert!(token_amount > 0, EInvalidAmountIn);
        
        update_cumulative_funding_rate(vault, token, ctx);

        // todo: get price from oracle
        let price = get_min_price(vault, token);

        let tusd_amount = token_amount * price / PRICE_PRECISION;
        tusd_amount = adjust_for_decimals(vault, tusd_amount, token, TUSD_ADDRESS);
        assert!(tusd_amount > 0, EInvalidTusdAmount);

        //todo
        let fee_basis_points = get_buy_tusd_fee_basis_points(vault, token, tusd_amount);
        let amount_after_fees = collect_swap_fees(vault, token, token_amount, fee_basis_points);
        let mint_amount = amount_after_fees * price / PRICE_PRECISION;
        mint_amount = adjust_for_decimals(vault, mint_amount, token, TUSD_ADDRESS);

        increase_tusd_amount(vault, token, mint_amount);
        increase_pool_amount(vault, token, amount_after_fees);

        vault.tusd_supply_amount = vault.tusd_supply_amount + mint_amount;

        event::emit(BuyTUSDEvent { receiver: tx_context::sender(ctx), token: token, token_amount, mint_amount, fee_basis_points });

        mint_amount
    }

    // todo: change epoch to timestamp
    fun update_cumulative_funding_rate(vault: &mut Vault, collateral_token: address, ctx: &mut TxContext) {
        let last_funding_time = *vec_map::get(&vault.last_funding_times, &collateral_token);
        let funding_interval = vault.funding_interval;
        if (last_funding_time == 0) {
            let last_funding_time_ref = vec_map::get_mut(&mut vault.last_funding_times, &collateral_token);
            *last_funding_time_ref = tx_context::epoch(ctx) / funding_interval * funding_interval;
        } else {
            if (last_funding_time + funding_interval  > tx_context::epoch(ctx)) {
                return
            };

            let funding_rate = get_next_funding_rate(vault, collateral_token, ctx);

            let cumulative_funding_rates = vec_map::get_mut(&mut vault.cumulative_funding_rates, &collateral_token);
            *cumulative_funding_rates = *cumulative_funding_rates + funding_rate;
            let last_funding_time_ref = vec_map::get_mut(&mut vault.last_funding_times, &collateral_token);
            *last_funding_time_ref = tx_context::epoch(ctx) / funding_interval * funding_interval;

            event::emit(UpdateFundingRateEvent { collateral_token, cumulative_funding_rates: *cumulative_funding_rates });
        }
    }

    fun get_next_funding_rate(vault: &Vault, token: address, ctx: &mut TxContext): u64 {
        let last_funding_times = *vec_map::get(&vault.last_funding_times, &token);
        let funding_interval = vault.funding_interval;
        let timestamp = tx_context::epoch(ctx);
        if (last_funding_times + funding_interval > timestamp) { return 0 };

        let intervals = (timestamp - last_funding_times) / funding_interval;
        let pool_amount = *vec_map::get(&vault.pool_amounts, &token);
        if (pool_amount == 0) { return 0 };

        let is_stable_token = *vec_map::get(&vault.stable_tokens, &token);
        let funding_rate_ractor = if (is_stable_token) vault.stable_funding_rate_factor else vault.funding_rate_factor;
        let next_funding_rate = funding_rate_ractor * *vec_map::get(&vault.reserved_amounts, &token) * intervals * pool_amount;

        next_funding_rate
    }

    fun collect_swap_fees(vault: &mut Vault, token: address, token_amount: u64, fee_basis_points: u64): u64 {
        let after_fee_amount = token_amount * (BASIS_POINTS_DIVISOR - fee_basis_points) / BASIS_POINTS_DIVISOR;
        let fee_amount = token_amount - after_fee_amount;
        let fee_reserve = vec_map::get_mut(&mut vault.fee_reserves, &token);
        *fee_reserve = *fee_reserve + fee_amount;
        event::emit(CollectSwapFeesEvent { token: token, fee_in_usd:token_to_usd_min(vault, token, fee_amount), fee_token_amount:fee_amount });

        after_fee_amount
    }

    fun adjust_for_decimals(vault: &mut Vault, amount: u64, token_div: address, token_mul: address): u64 {
        let decimals_div = if (token_div == TUSD_ADDRESS) TUSD_DECIMALS else *vec_map::get(&vault.token_decimals, &token_div);
        let decimals_mul = if (token_mul == TUSD_ADDRESS) TUSD_DECIMALS else *vec_map::get(&vault.token_decimals, &token_mul);
        let amount = amount * math::pow(10, decimals_mul)/ math::pow(10, decimals_div);

        amount
    }

    fun increase_tusd_amount(vault: &mut Vault, token: address, amount: u64) {
        let tusd_amount = vec_map::get_mut(&mut vault.tusd_amounts, &token);
        *tusd_amount = *tusd_amount + amount;

        event::emit(IncreaseTusdAmountEvent { token, amount: *tusd_amount});
    }

    fun increase_pool_amount(vault: &mut Vault, token: address, amount: u64) {
        let pool_amount = vec_map::get_mut(&mut vault.pool_amounts, &token);
        *pool_amount = *pool_amount + amount;

        event::emit(IncreasePoolAmountEvent { token, amount: *pool_amount});
    }

    fun get_target_tusd_amount(vault: &Vault, token: address): u64 {
        let supply = vault.tusd_supply_amount;
        if (supply == 0) { return 0 };
        let weight = *vec_map::get(&vault.token_weights, &token);
        let target_weight = weight * supply / vault.total_token_weights;
        target_weight
    }

    fun token_to_usd_min(vault: &mut Vault, token: address, token_amount: u64): u64 {
        if (token_amount == 0) { return 0 };
        let price = get_min_price(vault, token);
        let decimals = *vec_map::get(&vault.token_decimals, &token);

        token_amount * price / math::pow(10 , decimals)
    }

    fun get_min_price(vault: &mut Vault, token: address): u64 {
        //todo: get price from oracle
        1
    }

    fun get_max_price(vault: &mut Vault, token: address): u64 {
        //todo: get price from oracle
        1
    }

    fun get_buy_tusd_fee_basis_points(vault: &Vault, token: address, tusd_amount: u64): u64 {
		get_fee_basis_points(vault, token, tusd_amount, vault.mint_burn_fee_basis_points, vault.tax_basis_points, true)
    }

	fun get_sell_tusd_fee_basis_points(vault: &Vault, token: address, tusd_amount: u64): u64 {
		get_fee_basis_points(vault, token, tusd_amount, vault.mint_burn_fee_basis_points, vault.tax_basis_points, false)
    }

	fun get_swap_fee_basis_points(vault: &mut Vault, token_in: address, token_out: address, tusd_amount: u64): u64 {
		let is_token_in_stable = *vec_map::get(&vault.stable_tokens, &token_in);
		let is_token_out_stable = *vec_map::get(&vault.stable_tokens, &token_in);
        let is_stable_swap = is_token_in_stable && is_token_out_stable;
        let base_bps = if (is_stable_swap) vault.stable_swap_fee_basis_points else vault.swap_fee_basis_points;
        let tax_bps = if (is_stable_swap) vault.stable_tax_basis_points else vault.tax_basis_points;
        let fee_basis_points_0 = get_fee_basis_points(vault, token_in, tusd_amount, base_bps, tax_bps, true);
        let fees_basis_points_1 = get_fee_basis_points(vault, token_out, tusd_amount, base_bps, tax_bps, false);
        let point = if (fee_basis_points_0 > fees_basis_points_1) fee_basis_points_0 else fees_basis_points_1;
		point
    }

	fun get_fee_basis_points(vault: &Vault, token: address, usdg_delta: u64 ,fee_basis_points: u64, tax_basis_points: u64, increment: bool): u64 {
		let has_dynamic_fees = vault.has_dynamic_fees;
        if (has_dynamic_fees) { return fee_basis_points };

        let initial_amount = *vec_map::get(&vault.tusd_amounts, &token);
        let next_amount = initial_amount + usdg_delta;
        if (!increment) {
            next_amount = if(usdg_delta > initial_amount) 0 else initial_amount - usdg_delta;
        };

        let target_amount = get_target_tusd_amount(vault, token);
        if (target_amount == 0) { return fee_basis_points };

        let initial_diff = if(initial_amount > target_amount) initial_amount - target_amount else target_amount - initial_amount;
        let next_diff = if(next_amount > target_amount) next_amount - target_amount else target_amount - next_amount;

        if (next_diff < initial_diff) {
            let rebate_bps = tax_basis_points * initial_diff / target_amount;
            return if(rebate_bps > fee_basis_points) 0 else fee_basis_points - rebate_bps
        };

        let average_diff = (initial_diff + next_diff) / 2;
        if (average_diff > target_amount) {
            average_diff = target_amount;
        };
        let tax_bps = tax_basis_points * average_diff / target_amount;
        fee_basis_points + tax_bps
    }

}