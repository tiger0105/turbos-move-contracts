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
    use turbos::tools;
    use std::string::{Self, String};
    use turbos_time_oracle::time::{Self, Timestamp};
    use turbos_aum_oracle::aum::{Self, AUM};
    use turbos_price_oracle::price::{Self, PriceFeed};

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
    const EMarkPriceHigherThanLimit: u64 = 18;
    const EMarkPriceLowerThanLimit: u64 = 19;
    const EMaxGlobalLongsExceeded: u64 = 20;
    const EMaxGlobalShortsExceeded: u64 = 21;
    const EInsufficientCollateralForFees: u64 = 22;
    const EPositionSizeExceeded: u64 = 23;
    const EPositionCollateralExceeded: u64 = 24;
    const EReserveExceedsPool: u64 = 25;
    const EMaxShortsExceeded: u64 = 26;
    const EInvalidPositionSize: u64 = 27;
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
    const FUNDING_RATE_PRECISION: u64 = 1000000;
    /** constants end */

    /// Coin<TLP> is the token used to mark the liquidity pool share.
    struct TLP has drop { }

    /// Belongs to the creator of the vault.
    struct ManagerCap has key, store { id: UID }

    struct Position has store {
        id: UID,
        sender: address,
        size: u64,
        collateral: u64,
        average_price: u64,
        entry_funding_rate: u64,
        reserve_amount: u64,
        realised_pnl: u64 ,
        last_increased_time: u64,
    }

    struct Positions has key, store {
        id: UID,
        position_data: VecMap<String, Position>,
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
        // default: 30 | 0.3%
        deposit_fee: u64,
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
        // default: 100
        // allows for a small amount of decrease of leverage
        increase_position_buffer_basis_points: u64,
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
        global_long_sizes: u64,
        global_short_sizes: u64,
        global_short_average_prices: u64,
        max_global_long_sizes: u64,
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

    struct DecreasePoolAmountEvent has copy, drop {
        pool: ID,
        amount: u64,
    }

    struct CollectMarginFeesEvent has copy, drop {
        pool: ID,
        fee_in_usd: u64,
        fee_token_amount: u64,
    }

    struct IncreaseReservedAmountEvent has copy, drop {
        pool: ID,
        amount: u64,
    }

    struct DecreaseReservedAmountEvent has copy, drop {
        pool: ID,
        amount: u64,
    }

    struct IncreaseGuaranteedUsdEvent has copy, drop {
        pool: ID,
        amount: u64,
    }

    struct DecreaseGuaranteedUsdEvent has copy, drop {
        pool: ID,
        amount: u64,
    }

    struct IncreasePositionEvent has copy, drop {
        position_key: String,
        collateral_pool_id: ID,
        index_pool_id: ID,
        collateral_delta_usd: u64,
        size_delta: u64,
        is_long: bool,
        price: u64,
        fee: u64,
    }

    //fun init(_: &mut TxContext) {}

    fun init(ctx: &mut TxContext) {
        transfer::transfer(ManagerCap { id: object::new(ctx) }, tx_context::sender(ctx));

        let tlp_supply = balance::create_supply(TLP {});
        transfer::share_object(Vault {
            id: object::new(ctx),
            tlp_supply,
            tusd_supply_amount: 0,
            is_swap_enabled: false,
            aum_addition: 0,
            aum_deduction: 0, 
            white_listed_token_count: 0,
            max_leverage: 50, 
            liquidation_fee_usd: 2, //todo 2usd
            deposit_fee: 30,
            tax_basis_points: 50,
            stable_tax_basis_points: 30,
            mint_burn_fee_basis_points: 30,
            swap_fee_basis_points: 30,
            stable_swap_fee_basis_points: 4,
            margin_fee_basis_points: 10,
            increase_position_buffer_basis_points: 100,
            min_profit_time: 0,
            has_dynamic_fees: false,
            funding_interval: 28800,
            funding_rate_factor: 100,
            stable_funding_rate_factor: 100,
            total_token_weights: 0,
        });

        transfer::share_object(Positions {
           id: object::new(ctx), 
           position_data: vec_map::empty(),
        });

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
            global_long_sizes: 0,
            global_short_sizes: 0,
            global_short_average_prices: 0,
            max_global_long_sizes: 0,
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
        token_price_feed: &PriceFeed,
        min_tusd: u64, 
        min_tlp: u64, 
        aum_obj: &AUM,
        timestamp: &Timestamp,
        ctx: &mut TxContext
    ) {
        assert!(pool.is_white_listed, EPoolNotWhiteListed);

        let token_balance = coin::into_balance(token);
        let token_amount = balance::value(&token_balance);
        assert!(token_amount > 0, EInvalidAmountIn);

		// buy tusd from vault
		let tusd_amount = buy_tusd(vault, pool, token_amount, timestamp, token_price_feed, ctx);
		assert!(tusd_amount > min_tusd, EInsufficientTusdOutput);

        let aum_in_tusd = aum::amount(aum_obj);
        let tlp_supply = balance::supply_value(&vault.tlp_supply);

		balance::join(&mut pool.token, token_balance);

		let mint_amount = if(aum_in_tusd == 0) tusd_amount else tusd_amount * tlp_supply / aum_in_tusd;
		assert!(mint_amount > min_tlp, EInsufficientTlpOutput);

        // increase glp supply
        let balance = balance::increase_supply(&mut vault.tlp_supply, mint_amount);

        pool.last_liquidity_added_at = pool.last_liquidity_added_at + time::unix(timestamp);
        event::emit(AddLiquidityEvent { account: tx_context::sender(ctx), pool: object::id(pool), amount: token_amount, aum_in_tusd, tlp_supply, tusd_amount, mint_amount });

        let balance = coin::from_balance(balance, ctx);

        transfer::transfer(
            balance,
            tx_context::sender(ctx)
        );
    }

    entry fun increase_position<T, P>(
        vault: &mut Vault, 
        collateral_pool: &mut Pool<T>, 
        index_pool: &mut Pool<P>, 
        index_price_feed: &PriceFeed, 
        collateral_price_feed: &PriceFeed, 
        positions: &mut Positions,
        token: Coin<T>, 
        min_out: u64,
        size_delta: u64,
        is_long: bool,
        price: u64,
        timestamp: &Timestamp,
        ctx: &mut TxContext
    ) {
        let token_balance = coin::into_balance(token);
        let token_amount = balance::value(&token_balance);
        assert!(token_amount > 0, EInvalidAmountIn);

        let mark_price = if(is_long) get_max_price(vault, index_pool, index_price_feed) else get_min_price(vault, index_pool, index_price_feed);
        if (is_long) {
            assert!(mark_price <= price, EMarkPriceHigherThanLimit);
        } else {
            assert!(mark_price >= price, EMarkPriceLowerThanLimit);
        };

        let sender_address = tx_context::sender(ctx);
        let vault_address = object::id_address(vault);
        let pool_address = object::id_address(collateral_pool);
        let position_key = tools::get_position_key(sender_address, vault_address, pool_address, is_long);
        if (!vec_map::contains(&positions.position_data, &position_key)) {
            // create position
            vec_map::insert(&mut positions.position_data, position_key, Position {
                id: object::new(ctx),
                sender: sender_address,
                size: size_delta,
                collateral: 0,
                average_price: mark_price,
                entry_funding_rate: 0,
                reserve_amount: 0,
                realised_pnl: 0 ,
                last_increased_time: 0,
            });
        };
        let position_imut = vec_map::get(&positions.position_data, &position_key);
        let (after_fee_amount, fee_amount) = collect_fees<T>(vault, collateral_pool, position_imut ,token_amount, is_long, size_delta, collateral_price_feed);
        if(fee_amount > 0) {
            let fee_balance = balance::split(&mut token_balance, fee_amount);
            //todo 30% to DAO
            balance::join(&mut collateral_pool.token, fee_balance);
        };
        balance::join(&mut collateral_pool.token, token_balance);

        //validate global size
        if (size_delta>0) {
            if (is_long) {
                let max_global_long_sizes = collateral_pool.max_global_long_sizes;
                if (max_global_long_sizes > 0) {
                    assert!((collateral_pool.global_long_sizes + size_delta) <= max_global_long_sizes, EMaxGlobalLongsExceeded);
                }
            } else {
                let max_global_short_sizes = collateral_pool.max_global_short_sizes;
                if (max_global_short_sizes > 0) {
                    assert!((collateral_pool.global_short_sizes + size_delta) <= max_global_short_sizes, EMaxGlobalShortsExceeded);
                }
            };
        };

        // todo short tracker
        // todo token validate
        update_cumulative_funding_rate(vault, collateral_pool, timestamp, ctx);

        let position = vec_map::get_mut(&mut positions.position_data, &position_key);
        if (size_delta > 0) {
            position.average_price = get_next_average_price(
                mark_price,
                position.size,
                size_delta,
                position.average_price,
                is_long,
                position.last_increased_time,
                index_pool.min_profit_basis_points,
                vault.min_profit_time,
                timestamp,
            );
        };
        let fee = collect_margin_fees(vault, collateral_pool, index_pool, position, size_delta, collateral_price_feed);
        let collateral_delta = after_fee_amount;
        let collateral_delta_usd = token_to_usd_min(vault, collateral_pool, collateral_delta, collateral_price_feed);
        
        position.collateral = position.collateral + collateral_delta_usd;
        assert!(position.collateral>0, EInsufficientCollateralForFees);

        position.collateral = position.collateral - fee;
        position.entry_funding_rate = collateral_pool.cumulative_funding_rates;
        position.size = position.size + size_delta;
        position.last_increased_time = time::unix(timestamp);
        assert!(position.size>0, EInvalidPositionSize);

        validate_position(position.size, position.collateral);
        // todo validate_liquidation

        // reserve tokens to pay profits on the position
        let reserve_delta = usd_to_token_max(vault, collateral_pool, size_delta, collateral_price_feed);
        position.reserve_amount = position.reserve_amount + reserve_delta;
        collateral_pool.reserved_amounts = collateral_pool.reserved_amounts + reserve_delta; 
        assert!(collateral_pool.reserved_amounts <= collateral_pool.pool_amounts, EReserveExceedsPool);
        event::emit(IncreaseReservedAmountEvent { pool: object::id(collateral_pool), amount: reserve_delta});

        if (is_long) {
            increase_guaranteed_usd(collateral_pool, size_delta + fee);
            decrease_guaranteed_usd(collateral_pool, collateral_delta_usd);

            increase_pool_amount(collateral_pool, collateral_delta);
            let fee_tokens = usd_to_token_min(vault, collateral_pool, fee, collateral_price_feed);
            decrease_pool_amount(collateral_pool, fee_tokens);
        } else {
            if (index_pool.global_short_sizes == 0) {
                index_pool.global_short_average_prices = mark_price;
            } else {
                index_pool.global_short_average_prices = get_next_global_short_average_price(index_pool, mark_price, size_delta);

            };
            increase_global_short_size(vault, index_pool, size_delta);
        };

        event::emit(IncreasePositionEvent { 
            position_key: position_key,
            collateral_pool_id: object::id(collateral_pool),
            index_pool_id: object::id(index_pool),
            collateral_delta_usd: collateral_delta_usd,
            size_delta: size_delta,
            is_long: is_long,
            price: mark_price,
            fee: fee,
        });
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    fun get_next_global_short_average_price<P>(index_pool: &mut Pool<P>, next_price: u64, size_delta: u64): u64 {
        let size = index_pool.global_short_sizes;
        let average_price = index_pool.global_short_average_prices;
        let price_delta = if(average_price > next_price) average_price - next_price else next_price - average_price;
        let delta = size * price_delta / average_price;
        let has_profit = average_price > next_price;

        let next_size = size + size_delta;
        let divisor = if(has_profit) next_size - delta else next_size + delta;

        next_price * next_size / divisor
    }

    fun get_next_average_price(
        price: u64, 
        position_size: u64, 
        size_delta: u64,
        average_price: u64, 
        is_long: bool, 
        last_increased_time: u64,
        min_profit_basis_points: u64,
        min_profit_time: u64,
        timestamp: &Timestamp,
    ): u64 {
        let (has_profit, delta) = get_delta(price, position_size, average_price, is_long, last_increased_time, min_profit_basis_points, min_profit_time, timestamp);
        let next_size = position_size + size_delta;
        let divisor;
        if (is_long) {
            divisor = if(has_profit) next_size + delta else next_size - delta;
        } else {
            divisor = if(has_profit) next_size - delta else next_size + delta;
        };

        price * next_size / divisor
    }

    fun get_delta(
        price: u64, 
        position_size: u64, 
        average_price: u64, 
        is_long: bool, 
        last_increased_time: u64,
        min_profit_basis_points: u64,
        min_profit_time: u64,
        timestamp: &Timestamp,
    ): (bool, u64) {
        //_validate(_averagePrice > 0, 38);
        let price_delta = if(average_price > price) average_price - price else price - average_price;
        let delta = position_size * price_delta / average_price;

        let has_profit;

        if (is_long) {
            has_profit = price > average_price;
        } else {
            has_profit = average_price > price;
        };

        // if the minProfitTime has passed then there will be no min profit threshold
        // the min profit threshold helps to prevent front-running issues
        let min_bps = if (time::unix(timestamp) > last_increased_time + min_profit_time) 0 else min_profit_basis_points;
        if (has_profit && delta * BASIS_POINTS_DIVISOR <= position_size * min_bps) {
            delta = 0;
        };

        (has_profit, delta)
    }

    fun collect_margin_fees<T, P>(
        vault: &Vault,
        collateral_pool: &mut Pool<T>,
        index_pool: &Pool<P>,
        position: &Position,
        size_delta: u64,
        price_feed: &PriceFeed
    ): u64 {
        let fee_usd = get_position_fee(vault, size_delta);

        let funding_fee = get_funding_fee(collateral_pool, position);
        fee_usd = fee_usd + funding_fee;

        let fee_tokens = usd_to_token_min<T>(vault, collateral_pool, fee_usd, price_feed);
        collateral_pool.fee_reserves = collateral_pool.fee_reserves + fee_tokens;

        event::emit(CollectSwapFeesEvent { pool: object::id(collateral_pool), fee_in_usd:fee_usd, fee_token_amount:fee_tokens });

        fee_usd
    }

    fun get_position_fee(vault: &Vault, size_delta: u64): u64 {
        if (size_delta == 0) { return 0 };
        let after_fee_usd = size_delta * (BASIS_POINTS_DIVISOR / vault.margin_fee_basis_points) / BASIS_POINTS_DIVISOR;

        size_delta - after_fee_usd
    }

    fun get_funding_fee<T>(collateral_pool: &Pool<T>, position: &Position): u64 {
        if (position.size == 0) { return 0 };

        let funding_rate = collateral_pool.cumulative_funding_rates / position.entry_funding_rate;
        if (funding_rate == 0) { return 0 };

        position.size * funding_rate / FUNDING_RATE_PRECISION
    }

    fun validate_position(size: u64, collateral: u64) {
        if (size == 0) {
            assert!(collateral == 0, EPositionSizeExceeded);
            return
        };
        assert!(size >= collateral, EPositionCollateralExceeded);
    }

    fun increase_reserved_amount<T>(pool: &mut Pool<T>, amount: u64) {
        pool.reserved_amounts = pool.reserved_amounts + amount; 
        assert!(pool.reserved_amounts<=pool.pool_amounts, EReserveExceedsPool);
        event::emit(IncreaseReservedAmountEvent { pool: object::id(pool), amount: amount});
    }

    fun decrease_reserved_amount<T>(pool: &mut Pool<T>, amount: u64) {
        pool.reserved_amounts = pool.reserved_amounts - amount; 
        event::emit(DecreaseReservedAmountEvent { pool: object::id(pool), amount: amount});
    }

    fun increase_global_short_size<T>(vault: &Vault, pool: &mut Pool<T>, amount: u64) {
        pool.global_short_sizes = pool.global_short_sizes + amount;

        let max_size = pool.max_global_short_sizes;
        if (max_size != 0) {
            assert!(pool.global_short_sizes<=max_size, EMaxShortsExceeded);
        }
    }

    fun decrease_global_short_size<T>(vault: &Vault, pool: &mut Pool<T>, amount: u64) {
        if (amount > pool.global_short_sizes) {
          pool.global_short_sizes = 0;
          return
        };

        pool.global_short_sizes = pool.global_short_sizes - amount
    }

    fun increase_guaranteed_usd<T>(pool: &mut Pool<T>, amount: u64) {
        pool.guaranteed_usd = pool.guaranteed_usd + amount;
        event::emit(IncreaseGuaranteedUsdEvent { pool: object::id(pool), amount: amount});
    }

    fun decrease_guaranteed_usd<T>(pool: &mut Pool<T>, amount: u64) {
        pool.guaranteed_usd = pool.guaranteed_usd - amount;
        event::emit(DecreaseGuaranteedUsdEvent { pool: object::id(pool), amount: amount});
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

    fun buy_tusd<T>(vault: &mut Vault, pool: &mut Pool<T>, token_amount: u64, timestamp:&Timestamp, price_feed: &PriceFeed, ctx: &mut TxContext): u64 {
        assert!(token_amount > 0, EInvalidAmountIn);
        
        update_cumulative_funding_rate<T>(vault, pool, timestamp, ctx);

        // todo: get price from oracle
        let price = get_min_price(vault, pool, price_feed);
        let token_decimals = pool.token_decimals;

        let tusd_amount = token_amount * price / PRICE_PRECISION;
        tusd_amount = adjust_for_decimals(tusd_amount, token_decimals, TUSD_DECIMALS);
        assert!(tusd_amount > 0, EInvalidTusdAmount);

        //todo
        let fee_basis_points = get_buy_tusd_fee_basis_points(vault, pool, tusd_amount);
        let amount_after_fees = collect_swap_fees(vault, pool, token_amount, fee_basis_points, price_feed);
        let mint_amount = amount_after_fees * price / PRICE_PRECISION;
        mint_amount = adjust_for_decimals(mint_amount, token_decimals, TUSD_DECIMALS);

        increase_tusd_amount(pool, mint_amount);
        increase_pool_amount(pool, amount_after_fees);

        vault.tusd_supply_amount = vault.tusd_supply_amount + mint_amount;

        event::emit(BuyTUSDEvent { receiver: tx_context::sender(ctx), pool: object::id(pool), token_amount, mint_amount, fee_basis_points });

        mint_amount
    }

    fun update_cumulative_funding_rate<T>(vault: &mut Vault, pool: &mut Pool<T>, timestamp: &Timestamp, ctx: &mut TxContext) {
        let current_time = time::unix(timestamp);
        let last_funding_times = pool.last_funding_times;
        let funding_interval = vault.funding_interval;
        if (last_funding_times == 0) {
            pool.last_funding_times = current_time / funding_interval * funding_interval;
        } else {
            if (last_funding_times + funding_interval  > current_time) {
                return
            };

            let funding_rate = get_next_funding_rate<T>(vault, pool, timestamp, ctx);

            pool.cumulative_funding_rates = pool.cumulative_funding_rates + funding_rate;
            pool.last_funding_times = current_time / funding_interval * funding_interval;

            event::emit(UpdateFundingRateEvent { pool: object::id(pool), cumulative_funding_rates: pool.cumulative_funding_rates });
        }
    }

    fun get_next_funding_rate<T>(vault: &Vault, pool: &Pool<T>, timestamp: &Timestamp, ctx: &mut TxContext): u64 {
        let last_funding_times = pool.last_funding_times;
        let funding_interval = vault.funding_interval;
        let current_time = time::unix(timestamp);
        if (last_funding_times + funding_interval > current_time) { return 0 };

        let intervals = (current_time - last_funding_times) / funding_interval;
        let pool_amounts = pool.pool_amounts;
        if (pool_amounts == 0) { return 0 };

        let is_stable_token = pool.is_stable_token;
        let funding_rate_ractor = if (is_stable_token) vault.stable_funding_rate_factor else vault.funding_rate_factor;
        let next_funding_rate = funding_rate_ractor * pool.reserved_amounts * intervals * pool_amounts;

        next_funding_rate
    }

    fun collect_swap_fees<T>(vault: &mut Vault, pool: &mut Pool<T>, token_amount: u64, fee_basis_points: u64, price_feed: &PriceFeed): u64 {
        let after_fee_amount = token_amount * (BASIS_POINTS_DIVISOR - fee_basis_points) / BASIS_POINTS_DIVISOR;
        let fee_amount = token_amount - after_fee_amount;
        pool.fee_reserves = pool.fee_reserves + fee_amount;
        event::emit(CollectSwapFeesEvent { pool: object::id(pool), fee_in_usd:token_to_usd_min(vault, pool, fee_amount, price_feed), fee_token_amount:fee_amount });

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

    fun decrease_pool_amount<T>(pool: &mut Pool<T>, amount: u64) {
        pool.pool_amounts = pool.pool_amounts - amount;

        event::emit(DecreasePoolAmountEvent { pool: object::id(pool), amount: pool.pool_amounts});
    }

    fun get_target_tusd_amount<T>(vault: &Vault, pool: &Pool<T>): u64 {
        let supply = vault.tusd_supply_amount;
        if (supply == 0) { return 0 };
        let weight = pool.token_weights;
        let target_weight = weight * supply / vault.total_token_weights;
        target_weight
    }

    fun token_to_usd_min<T>(vault: &Vault, pool: &Pool<T>, token_amount: u64, price_feed: &PriceFeed): u64 {
        if (token_amount == 0) { return 0 };
        let price = get_min_price(vault, pool, price_feed);
        let decimals = pool.token_decimals;

        token_amount * price / math::pow(10 , decimals)
    }

    fun usd_to_token_min<T>(vault: &Vault, pool: &Pool<T>, usd_amount: u64, price_feed: &PriceFeed): u64 {
        if (usd_amount == 0) { return 0 };
        let price = get_min_price(vault, pool, price_feed);
        let decimals = pool.token_decimals;

        usd_amount * math::pow(10 , decimals) / price
    }

    fun usd_to_token_max<T>(vault: &Vault, pool: &Pool<T>, usd_amount: u64, price_feed: &PriceFeed): u64 {
        if (usd_amount == 0) { return 0 };
        let price = get_max_price(vault, pool, price_feed);
        let decimals = pool.token_decimals;

        usd_amount * math::pow(10 , decimals) / price
    }

    fun get_min_price<T>(vault: &Vault, pool: &Pool<T>, price_feed: &PriceFeed): u64 {
        //todo: spread_basis_points
        price::price(price_feed)
    }

    fun get_max_price<T>(vault: &Vault, pool: &Pool<T>, price_feed: &PriceFeed): u64 {
        //todo: spread_basis_points
        price::price(price_feed)
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

    fun collect_fees<T>(
        vault: &Vault, 
        pool: &mut Pool<T>,
        position: &Position,
        amount_in: u64,
        is_long: bool,
        size_delta: u64,
        price_feed: &PriceFeed,
    ): (u64, u64) {
        let should_deduct_fee = should_deduct_fee(
            vault,
            pool,
            position,
            amount_in,
            is_long,
            size_delta,
            price_feed,
        );

        let fee_amount = 0;
        if (should_deduct_fee) {
            let after_fee_amount = amount_in * (BASIS_POINTS_DIVISOR - vault.deposit_fee) / BASIS_POINTS_DIVISOR;
            fee_amount = amount_in - after_fee_amount;
            pool.fee_reserves = pool.fee_reserves + fee_amount;
            return (after_fee_amount, fee_amount)
        };

        (amount_in, fee_amount)
    }

    fun should_deduct_fee<T>(
        vault: &Vault, 
        pool: &Pool<T>,
        position: &Position,
        amount_in: u64,
        is_long: bool,
        size_delta: u64,
        price_feed: &PriceFeed,
    ): bool {
        // if the position is a short, do not charge a fee
        if (!is_long) { return false };

        // if the position size is not increasing, this is a collateral deposit
        if (size_delta == 0) { return true };

        let size = position.size;
        let collateral = position.collateral;

        // if there is no existing position, do not charge a fee
        if (size == 0) { return false };

        let next_size = size + size_delta;
        let collateral_delta = token_to_usd_min(vault, pool, amount_in, price_feed);
        let next_collateral = collateral + collateral_delta;

        let next_leverage = size * BASIS_POINTS_DIVISOR / collateral;
        // allow for a maximum of a increasePositionBufferBps decrease since there might be some swap fees taken from the collateral
        let next_leverage = next_size * (BASIS_POINTS_DIVISOR + vault.increase_position_buffer_basis_points) / next_collateral;

        // deduct a fee if the leverage is decreased
        next_leverage < next_leverage
    }
}