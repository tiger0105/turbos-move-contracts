// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

module turbos::vault {
    use sui::math;
    use sui::event;
    use std::vector;
    use sui::transfer;
    use sui::object::{Self, UID, ID};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance, Supply};
    use sui::tx_context::{Self, TxContext};
    use sui::vec_map::{Self, VecMap};
    use sui::dynamic_object_field as dof;

    /** errors */
    const EInsufficientTusdOutput: u64 = 0;
	const EInsufficientTlpOutput: u64 = 1;
    const EPoolNotWhiteListed: u64 = 2;
    const EInvalidAmountIn: u64 =3;
    const EInvalidAmountOut: u64 =4;
    const EInvalidTusdAmount: u64 = 5;
    const EInvalidMaxLeverage: u64 = 6;
    const EInvalidTaxBasisPoint: u64 = 7;
    const EInvalidStableTaxBasisPoints: u64 = 8;
    const EInvalidMintBurnFeeBasisPoints: u64 = 9;
    const EInvalidSwapFeeBasisPoints: u64 = 10;
    const EInvalidStableSwapFeeBasisPoints: u64 = 11;
    const EInvalidMarginFeeBasisPoints: u64 = 12;
    const EInvalidLiquidationFeeUsd: u64 = 13;
    const EInvalidFundingInterval: u64 = 14;
    const EInvalidFundingRateFactor: u64 = 15;
    const EInvalidStableFundingRateFactor: u64 = 16;
    const EPoolNotCreated: u64 = 17;
    /** errors end */
    
    /** constants */
    const MAX_FEE_BASIS_POINTS: u64 = 500; //5%
    const MIN_FUNDING_RATE_INTERVAL: u64 = 3600; //1 hours
    const MAX_FUNDING_RATE_FACTOR: u64 = 10000; //1%
    const PRICE_PRECISION: u64 = 100000000;
    const GLP_PRECISION: u64 = 1000000000000000000;
    const TUSD_DECIMALS: u8 = 18;
    const TUSD_ADDRESS: address = @0x1;
    const BASIS_POINTS_DIVISOR: u64 = 10000;
    const MAX_LIQUIDATION_FEE_USD: u64 = 100000000000; // 100 usd decimals: 9
    /** constants end */

    /// Coin<TLP> is the token used to mark the liquidity pool share.
    struct TLP has drop { }

    /// Belongs to the creator of the vault.
    struct ManagerCap has key, store { id: UID }

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
        white_listed_token_count: u64,
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
        // default: 0
        min_profit_time: u64,
        // default: false
        has_dynamic_fees: bool,

        ///funding
        // default: 8 hours
        funding_interval: u64,
        funding_rate_factor: u64,
        stable_funding_rate_factor: u64,

        total_token_weights: u64,
    }

    struct Pool<phantom T> has key, store {
        id: UID,
        token: Balance<T>,
        token_decimals: u8,
        min_profit_basis_points: u64,
        is_white_listed: bool,
        is_stable_token: bool,
        is_shortable_token: bool,
        // tokenWeights allows customisation of index composition
        token_weights: u64, 
        // tusdAmounts tracks the amount of TUSD debt for each whitelisted token
        tusd_amounts: u64,
        // maxTusdAmounts allows setting a max amount of TUSD debt for a token
        max_tusd_amounts: u64,
        // poolAmounts tracks the number of received tokens that can be used for leverage
        // this is tracked separately from tokenBalances to exclude funds that are deposited as margin collateral
        pool_amounts: u64,
        // reservedAmounts tracks the number of tokens reserved for open leverage positions
        reserved_amounts: u64,
        // bufferAmounts allows specification of an amount to exclude from swaps
        // this can be used to ensure a certain amount of liquidity is available for leverage positions
        buffer_amounts: u64,
        // guaranteedUsd tracks the amount of USD that is "guaranteed" by opened leverage positions
        // this value is used to calculate the redemption values for selling of TUSD
        // this is an estimated amount, it is possible for the actual guaranteed value to be lower
        // in the case of sudden price decreases, the guaranteed value should be corrected
        // after liquidations are carried out
        guaranteed_usd: u64,

        // cumulativeFundingRates tracks the funding rates based on utilization
        cumulative_funding_rates: u64,
        // lastFundingTimes tracks the last time funding was updated for a token
        last_funding_times: u64,
        // feeReserves tracks the amount of fees per token
        fee_reserves: u64,
        global_short_sizes: u64,
        global_short_average_prices: u64,
        max_global_short_sizes: u64,
        last_liquidity_added_at: u64,
    }

    struct BuyTUSDEvent has copy, drop {
        receiver: address,
        pool: ID,
        token_amount: u64,
        mint_amount: u64,
        fee_basis_points: u64,
    }

    struct CollectSwapFeesEvent has copy, drop {
        pool: ID,
        fee_in_usd: u64,
        fee_token_amount: u64,
    }
    
    struct UpdateFundingRateEvent has copy, drop {
        pool: ID,
        cumulative_funding_rates: u64,
    }

    struct AddLiquidityEvent has copy, drop {
        account: address, 
        pool: ID,
        amount: u64,
        aum_in_tusd: u64, 
        tlp_supply: u64,
        tusd_amount: u64, 
        mint_amount: u64,
    }

    struct IncreaseTusdAmountEvent has copy, drop {
        pool: ID,
        amount: u64,
    }

    struct IncreasePoolAmountEvent has copy, drop {
        pool: ID,
        amount: u64,
    }

    //fun init(_: &mut TxContext) {}

    fun init(ctx: &mut TxContext) {
        transfer::transfer(ManagerCap { id: object::new(ctx) }, tx_context::sender(ctx));

        let tlp_supply = balance::create_supply(TLP {});
        let vault = Vault {
            id: object::new(ctx),
            tlp_supply,
            tusd_supply_amount: 0,
            is_swap_enabled: false,
            aum_addition: 0,
            aum_deduction: 0, 
            white_listed_token_count: 0,
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
        };
        transfer::share_object(vault);
    }

    entry fun create_pool<T> (
        _: &ManagerCap,
        vault: &mut Vault, 
        token_decimals: u8,
        min_profit_basis_points: u64,
        is_stable_token: bool,
        is_shortable_token: bool,
        token_weights: u64, 
        max_tusd_amounts: u64,
        ctx: &mut TxContext
    ) {
        let pool = Pool { 
            id: object::new(ctx),
            token: balance::zero<T>(),
            token_decimals,
            min_profit_basis_points,
            is_white_listed: true,
            is_stable_token,
            is_shortable_token,
            token_weights, 
            tusd_amounts: 0,
            max_tusd_amounts,
            pool_amounts: 0,
            reserved_amounts: 0,
            buffer_amounts: 0,
            guaranteed_usd: 0,
            cumulative_funding_rates: 0,
            last_funding_times: 0,
            fee_reserves: 0,
            global_short_sizes: 0,
            global_short_average_prices: 0,
            max_global_short_sizes: 0,
            last_liquidity_added_at: 0,
        };
        transfer::share_object(pool);
        //vector::push_back(&mut vault.pools, pool_id);
    }

    entry fun add_liquidity<T>(
        vault: &mut Vault, 
        pool: &mut Pool<T>, 
        token: Coin<T>, 
        min_tusd: u64, 
        min_tlp: u64, 
        ctx: &mut TxContext
    ) {
        assert!(pool.is_white_listed, EPoolNotWhiteListed);

        let token_balance = coin::into_balance(token);
        let token_amount = balance::value(&token_balance);
        assert!(token_amount > 0, EInvalidAmountIn);

		// buy tusd from vault
		let tusd_amount = buy_tusd(vault, pool, token_amount, ctx);
		assert!(tusd_amount > min_tusd, EInsufficientTusdOutput);

        // todo get aum from oracle
        let aum_in_tusd = 0;
        let tlp_supply = balance::supply_value(&vault.tlp_supply);

		balance::join(&mut pool.token, token_balance);

		let mint_amount = if(aum_in_tusd == 0) tusd_amount else tusd_amount * tlp_supply / aum_in_tusd;
		assert!(mint_amount > min_tlp, EInsufficientTlpOutput);

        // increase glp supply
        let balance = balance::increase_supply(&mut vault.tlp_supply, mint_amount);

        pool.last_liquidity_added_at = pool.last_liquidity_added_at + tx_context::epoch(ctx);
        event::emit(AddLiquidityEvent { account: tx_context::sender(ctx), pool: object::id(pool), amount: token_amount, aum_in_tusd, tlp_supply, tusd_amount, mint_amount });

        let balance = coin::from_balance(balance, ctx);

        transfer::transfer(
            balance,
            tx_context::sender(ctx)
        );
    }

    entry fun set_fees(
        _: &ManagerCap,
        vault: &mut Vault,
        tax_basis_points: u64,
        stable_tax_basis_points: u64,
        mint_burn_fee_basis_points: u64,
        swap_fee_basis_points: u64,
        stable_swap_fee_basis_points: u64,
        margin_fee_basis_points: u64,
        liquidation_fee_usd: u64,
        min_profit_time: u64,
        has_dynamic_fees: bool,
        ctx: &mut TxContext
    ) {
        assert!(tax_basis_points <= MAX_FEE_BASIS_POINTS, EInvalidTaxBasisPoint);
        assert!(stable_tax_basis_points <= MAX_FEE_BASIS_POINTS, EInvalidStableTaxBasisPoints);
        assert!(mint_burn_fee_basis_points <= MAX_FEE_BASIS_POINTS, EInvalidMintBurnFeeBasisPoints);
        assert!(swap_fee_basis_points <= MAX_FEE_BASIS_POINTS, EInvalidSwapFeeBasisPoints);
        assert!(stable_swap_fee_basis_points <= MAX_FEE_BASIS_POINTS, EInvalidStableSwapFeeBasisPoints);
        assert!(margin_fee_basis_points <= MAX_FEE_BASIS_POINTS, EInvalidMarginFeeBasisPoints);
        assert!(liquidation_fee_usd <= MAX_LIQUIDATION_FEE_USD, EInvalidLiquidationFeeUsd);

        vault.tax_basis_points = tax_basis_points;
        vault.stable_tax_basis_points = stable_tax_basis_points;
        vault.mint_burn_fee_basis_points = mint_burn_fee_basis_points;
        vault.swap_fee_basis_points = swap_fee_basis_points;
        vault.stable_swap_fee_basis_points = stable_swap_fee_basis_points;
        vault.margin_fee_basis_points = margin_fee_basis_points;
        vault.liquidation_fee_usd = liquidation_fee_usd;
        vault.min_profit_time = min_profit_time;
        vault.has_dynamic_fees = has_dynamic_fees;
    }

    entry fun set_funding_rate(
        _: &ManagerCap,
        vault: &mut Vault,
        funding_interval: u64,
        funding_rate_factor: u64,
        stable_funding_rate_factor: u64,
        ctx: &mut TxContext
    ) {
        assert!(funding_interval >= MIN_FUNDING_RATE_INTERVAL, EInvalidFundingInterval);
        assert!(funding_rate_factor <= MAX_FUNDING_RATE_FACTOR, EInvalidFundingRateFactor);
        assert!(stable_funding_rate_factor <= MAX_FUNDING_RATE_FACTOR, EInvalidStableFundingRateFactor);
        
        vault.funding_interval = funding_interval;
        vault.funding_rate_factor = funding_rate_factor;
        vault.stable_funding_rate_factor = stable_funding_rate_factor;
    }

    entry fun set_pool_config<T>(
        _: &ManagerCap,
        vault: &mut Vault,
        pool_id: ID,
        token_decimals: u8,
        min_profit_basis_points: u64,
        is_stable_token: bool,
        is_shortable_token: bool,
        token_weights: u64, 
        max_tusd_amounts: u64,
        ctx: &mut TxContext
    ) {
        let is_pool_created = dof::exists_<ID>(&vault.id, pool_id);
        assert!(is_pool_created, EPoolNotCreated);

        let pool = dof::borrow_mut<ID, Pool<T>>(&mut vault.id, pool_id);
        pool.token_decimals = token_decimals;
        pool.min_profit_basis_points = min_profit_basis_points;
        pool.is_stable_token = is_stable_token;
        pool.is_shortable_token = is_shortable_token;
        pool.token_weights = token_weights;
        pool.max_tusd_amounts = max_tusd_amounts;
    }

	// fun get_aum_in_tusd(vault: &mut Vault, maximise: bool): u64 {
    //     let aum = get_aum(vault, maximise);
    //     aum * math::pow(10 , TUSD_DECIMALS) / PRICE_PRECISION
    // }

    // fun get_aum(vault: &mut Vault, maximise: bool): u64 {
    //     let len = vector::length(&vault.all_whitelisted_tokens);
    //     let aum = vault.aum_addition;
    //     let aum_deduction = vault.aum_deduction;
    //     let short_profits = 0;
    //     let i = 0;
    //     while (i < len) {
    //         i = i + 1;
    //         let token = *vector::borrow(&vault.all_whitelisted_tokens, i);
    //         let is_whitelisted = *vec_map::get(&vault.white_listed_tokens, &token);
    //         if (is_whitelisted) {
    //             continue
    //         };

    //         let price = if (maximise) get_max_price(vault, token) else get_min_price(vault, token);
    //         let pool_amount = *vec_map::get(&vault.pool_amounts, &token);
    //         let decimals = *vec_map::get(&vault.token_decimals, &token);

    //         if (*vec_map::get(&vault.stable_tokens, &token)) {
    //             aum = aum + (pool_amount * price / math::pow(10, decimals));
    //         } else {
    //             let size = *vec_map::get(&vault.global_short_sizes, &token);
    //             if (size > 0) {
    //                 let (delta, has_profit) = get_global_short_delta(vault, token, price, size);
    //                 if (!has_profit) {
    //                     // add losses from shorts
    //                     aum = aum + delta;
    //                 } else {
    //                     short_profits = short_profits + delta;
    //                 };
    //             };

    //             let guaranteed_usd = *vec_map::get(&vault.guaranteed_usd, &token);
    //             aum = aum + guaranteed_usd;

    //             let reserved_amount = *vec_map::get(&vault.reserved_amounts, &token);
    //             aum = aum + ((pool_amount - reserved_amount) * price / math::pow(10, decimals));
    //         };
    //     };

    //     aum = if (short_profits > aum) 0 else (aum - short_profits);
    //     aum = if (aum_deduction > aum) 0 else (aum - aum_deduction);
    //     aum
    // }

    // fun get_global_short_delta(vault: &mut Vault, token: address, price: u64, size: u64): (u64, bool) {
    //     // todo: get price from short tracker 
    //     let average_price  = *vec_map::get(&vault.global_short_average_prices, &token);
    //     let priceDelta = if (average_price > price) average_price - price else price - average_price;
    //     let delta = size * priceDelta / average_price;
    //     (delta, average_price > price)
    // }

    fun buy_tusd<T>(vault: &mut Vault, pool: &mut Pool<T>, token_amount: u64, ctx: &mut TxContext): u64 {
        assert!(token_amount > 0, EInvalidAmountIn);
        
        update_cumulative_funding_rate<T>(vault, pool, ctx);

        // todo: get price from oracle
        let price = get_min_price(vault, pool);
        let token_decimals = pool.token_decimals;

        let tusd_amount = token_amount * price / PRICE_PRECISION;
        tusd_amount = adjust_for_decimals(tusd_amount, token_decimals, TUSD_DECIMALS);
        assert!(tusd_amount > 0, EInvalidTusdAmount);

        //todo
        let fee_basis_points = get_buy_tusd_fee_basis_points(vault, pool, tusd_amount);
        let amount_after_fees = collect_swap_fees(vault, pool, token_amount, fee_basis_points);
        let mint_amount = amount_after_fees * price / PRICE_PRECISION;
        mint_amount = adjust_for_decimals(mint_amount, token_decimals, TUSD_DECIMALS);

        increase_tusd_amount(pool, mint_amount);
        increase_pool_amount(pool, amount_after_fees);

        vault.tusd_supply_amount = vault.tusd_supply_amount + mint_amount;

        event::emit(BuyTUSDEvent { receiver: tx_context::sender(ctx), pool: object::id(pool), token_amount, mint_amount, fee_basis_points });

        mint_amount
    }

    // todo: change epoch to timestamp
    fun update_cumulative_funding_rate<T>(vault: &mut Vault, pool: &mut Pool<T>, ctx: &mut TxContext) {
        let last_funding_times = pool.last_funding_times;
        let funding_interval = vault.funding_interval;
        if (last_funding_times == 0) {
            pool.last_funding_times = tx_context::epoch(ctx) / funding_interval * funding_interval;
        } else {
            if (last_funding_times + funding_interval  > tx_context::epoch(ctx)) {
                return
            };

            let funding_rate = get_next_funding_rate<T>(vault, pool, ctx);

            pool.cumulative_funding_rates = pool.cumulative_funding_rates + funding_rate;
            pool.last_funding_times = tx_context::epoch(ctx) / funding_interval * funding_interval;

            event::emit(UpdateFundingRateEvent { pool: object::id(pool), cumulative_funding_rates: pool.cumulative_funding_rates });
        }
    }

    fun get_next_funding_rate<T>(vault: &Vault, pool: &Pool<T>, ctx: &mut TxContext): u64 {
        let last_funding_times = pool.last_funding_times;
        let funding_interval = vault.funding_interval;
        let timestamp = tx_context::epoch(ctx);
        if (last_funding_times + funding_interval > timestamp) { return 0 };

        let intervals = (timestamp - last_funding_times) / funding_interval;
        let pool_amounts = pool.pool_amounts;
        if (pool_amounts == 0) { return 0 };

        let is_stable_token = pool.is_stable_token;
        let funding_rate_ractor = if (is_stable_token) vault.stable_funding_rate_factor else vault.funding_rate_factor;
        let next_funding_rate = funding_rate_ractor * pool.reserved_amounts * intervals * pool_amounts;

        next_funding_rate
    }

    fun collect_swap_fees<T>(vault: &mut Vault, pool: &mut Pool<T>, token_amount: u64, fee_basis_points: u64): u64 {
        let after_fee_amount = token_amount * (BASIS_POINTS_DIVISOR - fee_basis_points) / BASIS_POINTS_DIVISOR;
        let fee_amount = token_amount - after_fee_amount;
        pool.fee_reserves = pool.fee_reserves + fee_amount;
        event::emit(CollectSwapFeesEvent { pool: object::id(pool), fee_in_usd:token_to_usd_min(vault, pool, fee_amount), fee_token_amount:fee_amount });

        after_fee_amount
    }

    fun adjust_for_decimals(amount: u64, token_div_decimals: u8, token_mul_decimals: u8): u64 {
        let amount = amount * math::pow(10, token_mul_decimals)/ math::pow(10, token_div_decimals);

        amount
    }

    fun increase_tusd_amount<T>(pool: &mut Pool<T>, amount: u64) {
        pool.tusd_amounts = pool.tusd_amounts + amount;

        event::emit(IncreaseTusdAmountEvent { pool: object::id(pool), amount: pool.tusd_amounts});
    }

    fun increase_pool_amount<T>(pool: &mut Pool<T>, amount: u64) {
        pool.pool_amounts = pool.pool_amounts + amount;

        event::emit(IncreasePoolAmountEvent { pool: object::id(pool), amount: pool.pool_amounts});
    }

    fun get_target_tusd_amount<T>(vault: &Vault, pool: &Pool<T>): u64 {
        let supply = vault.tusd_supply_amount;
        if (supply == 0) { return 0 };
        let weight = pool.token_weights;
        let target_weight = weight * supply / vault.total_token_weights;
        target_weight
    }

    fun token_to_usd_min<T>(vault: &mut Vault, pool: &Pool<T>, token_amount: u64): u64 {
        if (token_amount == 0) { return 0 };
        let price = get_min_price(vault, pool);
        let decimals = pool.token_decimals;

        token_amount * price / math::pow(10 , decimals)
    }

    fun get_min_price<T>(vault: &Vault, pool: &Pool<T>): u64 {
        //todo: get price from oracle
        1
    }

    fun get_max_price<T>(vault: &Vault, pool: &Pool<T>): u64 {
        //todo: get price from oracle
        1
    }

    fun get_buy_tusd_fee_basis_points<T>(vault: &Vault, pool: &Pool<T>, tusd_amount: u64): u64 {
		get_fee_basis_points(vault, pool, tusd_amount, vault.mint_burn_fee_basis_points, vault.tax_basis_points, true)
    }

	fun get_sell_tusd_fee_basis_points<T>(vault: &Vault, pool: &Pool<T>, tusd_amount: u64): u64 {
		get_fee_basis_points(vault, pool, tusd_amount, vault.mint_burn_fee_basis_points, vault.tax_basis_points, false)
    }

	// fun get_swap_fee_basis_points(vault: &mut Vault, token_in: address, token_out: address, tusd_amount: u64): u64 {
	// 	let is_token_in_stable = *vec_map::get(&vault.stable_tokens, &token_in);
	// 	let is_token_out_stable = *vec_map::get(&vault.stable_tokens, &token_in);
    //     let is_stable_swap = is_token_in_stable && is_token_out_stable;
    //     let base_bps = if (is_stable_swap) vault.stable_swap_fee_basis_points else vault.swap_fee_basis_points;
    //     let tax_bps = if (is_stable_swap) vault.stable_tax_basis_points else vault.tax_basis_points;
    //     let fee_basis_points_0 = get_fee_basis_points(vault, token_in, tusd_amount, base_bps, tax_bps, true);
    //     let fees_basis_points_1 = get_fee_basis_points(vault, token_out, tusd_amount, base_bps, tax_bps, false);
    //     let point = if (fee_basis_points_0 > fees_basis_points_1) fee_basis_points_0 else fees_basis_points_1;
	// 	point
    // }

	fun get_fee_basis_points<T>(vault: &Vault,  pool: &Pool<T>, tusd_delta: u64 ,fee_basis_points: u64, tax_basis_points: u64, increment: bool): u64 {
		let has_dynamic_fees = vault.has_dynamic_fees;
        if (!has_dynamic_fees) { return fee_basis_points };

        let initial_amount = pool.tusd_amounts;
        let next_amount = initial_amount + tusd_delta;
        if (!increment) {
            next_amount = if(tusd_delta > initial_amount) 0 else initial_amount - tusd_delta;
        };

        let target_amount = get_target_tusd_amount(vault, pool);
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