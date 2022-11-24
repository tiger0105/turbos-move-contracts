// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

/// Coin<USDC> is the mock token used to test in Turbos.
/// It has 9 decimals
module turbos::usdc {
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self};

    struct USDC has drop {}

    fun init(witness: USDC, ctx: &mut TxContext) {
        transfer::transfer(
            coin::create_currency(witness, 9, ctx),
            tx_context::sender(ctx)
        )
    }
}
