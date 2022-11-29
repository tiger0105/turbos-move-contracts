// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

module turbos_price_oracle::price {
    use sui::transfer::{Self, transfer, share_object};
    use sui::object::{Self, ID, UID};
    use std::option::{Self, Option};
    use sui::tx_context::{Self, TxContext};
    use std::string::{Self, String};

    struct PriceFeed has key {
        id: UID,
        symbol: String,
        price: u64,
        ema_price: u64, //unix timestamp
        decimal: u8,
        timestamp: u64,
    }

    /// Created as a single-writer object, unique
    struct AuthorityCap has key, store {
        id: UID,
    }

    // === Getters ===

    public fun price(price: &PriceFeed): u64 {
        price.price
    }

    public fun ema_price(price: &PriceFeed): u64 {
        price.price
    }

    public fun decimal(price: &PriceFeed): u8 {
        price.decimal
    }

    public fun timestamp(price: &PriceFeed): u64 {
        price.timestamp
    }

     public fun symbol(price: &PriceFeed): String {
        price.symbol
    }

    // === For maintainer ===
    fun init(ctx: &mut TxContext) {
        transfer(AuthorityCap {
            id: object::new(ctx),
        }, tx_context::sender(ctx));
    }

    public entry fun create_price_feed(
        _: &mut AuthorityCap,
        symbol: String,
        decimal: u8,
        ctx: &mut TxContext,
    ) {
        share_object(PriceFeed {
            id: object::new(ctx),
            symbol: symbol,
            price: 0,
            ema_price: 0,
            decimal: decimal, // default 9
            timestamp: 0,
        });
    }

    public entry fun update_price_feed(
        _: &mut AuthorityCap,
        price_feed: &mut PriceFeed,
        price: u64,
        ema_price: u64, //unix timestamp
        timestamp: u64,
        ctx: &mut TxContext,
    ) {
        price_feed.price = price;
        price_feed.ema_price = ema_price;
        price_feed.timestamp = timestamp;
    }

    public entry fun update_decimal(
        _: &mut AuthorityCap,
        price_feed: &mut PriceFeed,
        decimal: u8,
        ctx: &mut TxContext,
    ) {
        price_feed.decimal = decimal;
    }

    public entry fun update_symbol(
        _: &mut AuthorityCap,
        price_feed: &mut PriceFeed,
        symbol: String,
        ctx: &mut TxContext,
    ) {
        price_feed.symbol = symbol;
    }
}
