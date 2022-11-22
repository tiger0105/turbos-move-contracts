// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

module turbos::liquidity_manager {
    use sui::math;
    use std::vector;
    use sui::transfer;
    use sui::object::{Self, UID};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance, Supply};
    use sui::tx_context::{Self, TxContext};
    use sui::vec_map::{Self, VecMap};
	use turbos::vault::{Self, Vault, Pool};

    const EInsufficientTusdOutput: u64 = 0;
	const EInsufficientTlpOutput: u64 = 0;


    const PRICE_PRECISION:u64 = 100000000;
    const GLP_PRECISION:u64 = 1000000000000000000;
    const TUSD_DECIMALS:u64 = 18;
    const BASIS_POINTS_DIVISOR:u64 = 10000;

	struct Manager has key {

	}

    entry fun add_liquidity<T>(vault: &mut Vault, pool: &mut Pool<T>, token: Coin<T>, min_tusd: u64, min_tlp: u64, ctx: &mut TxContext) {
        transfer::transfer(
            add_liquidity_(vault, pool, token, ctx),
            tx_context::sender(ctx)
        );
    }

    fun add_liquidity_<T>(vault: &mut Vault, pool: &mut Pool<T>, token: Coin<T>, min_tusd: u64, min_tlp: u64, ctx: &mut TxContext): Coin<TLP> {
        // calcalate AUM
        let aum_in_usd = get_aum_in_usd(vault, object::id_address(&token));
        let tlp_supply = balance::supply_value(&vault.tlp_supply);

        let token_balance = coin::into_balance(token);
		balance::join(&mut pool.token, token_balance);

		// buy from vault
		let tusd_amount = vault::buy_tusd(vault, token, ctx);
		assert!(tusd_amount > min_tusd, EInsufficientTusdOutput);

		let mint_amount = if(aum_in_usd == 0) tusd_amount else tusd_amount * tlp_supply / aum_in_usd;
		assert!(mint_amount > min_tlp, EInsufficientTlpOutput);

        let balance = balance::increase_supply(&mut vault.tlp_supply, mint_amount);

        coin::from_balance(balance, ctx)
    }

	fun get_aum_in_usd(vault: &mut Vault, token: address): u64 {
        let aum = get_aum(vault, object::id_address(&token));
        aum * math::pow(10 ** TUSD_DECIMALS) / PRICE_PRECISION
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
}