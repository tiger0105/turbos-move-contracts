module turbos::helper {
	use sui::vec_map::{Self, VecMap};
	use turbos::vault::{Self, Vault, Pool};

	public fun get_buy_tusd_fee_basis_points(vault: &mut Vault, token: address, tusd_amount: u64): u64 {
		get_fee_basis_points(vault, token, tusd_amount, &vault.mint_burn_fee_basis_points, &vault.tax_basis_points, true)
    }

	public fun get_sell_tusd_fee_basis_points(vault: &mut Vault, token: address, tusd_amount: u64): u64 {
		get_fee_basis_points(vault, token, tusd_amount, &vault.mint_burn_fee_basis_points, &vault.tax_basis_points, false)
    }

	public fun get_swap_fee_basis_points(vault: &mut Vault, token_in: address, token_out: address, tusd_amount: u64): u64 {
		let is_token_in_stable = *vec_map::get(&vault.stable_tokens, &token_in);
		let is_token_out_stable = *vec_map::get(&vault.stable_tokens, &token_in);
        let is_stable_swap = is_token_in_stable && is_token_out_stable;
        let base_bps = if (is_stable_swap) &vault.stable_swap_fee_basis_points else &vault.swap_fee_basis_points;
        let tax_bps = if (is_stable_swap) &vault.stable_tax_basis_points else &vault.tax_basis_points;
        let fee_basis_points_0 = get_fee_basis_points(vault, token_in, tusd_amount, base_bps, tax_bps, true);
        let fees_basis_points_1 = get_fee_basis_points(vault, token_out, tusd_amount, base_bps, tax_bps, false);
        let point = if (fee_basis_points_0 > fees_basis_points_1) fee_basis_points_0 else fees_basis_points_1;
		point
    }

	public fun get_fee_basis_points(vault: &mut Vault, token: address, usdg_delta: u64 ,fee_basis_points: u64, tax_basis_points: u64, increment: bool): u64 {
		let has_dynamic_fees = &vault.has_dynamic_fees;
        if (has_dynamic_fees) { return fee_basis_points; };

        let initial_amount = *vec_map::get(&vault.tusd_amounts, &token);
        let next_amount = initial_amount + usdg_delta;
        if (!increment) {
            next_amount = if(usdg_delta > initial_amount) 0 else initial_amount - usdg_delta;
        };

        let target_amount = vault::get_target_tusd_amount(vault, token);
        if (target_amount == 0) { return fee_basis_points; };

        let initial_diff = if(initial_amount > target_amount) initial_amount - target_amount else target_amount - initial_amount;
        let next_diff = if(next_amount > target_amount) next_amount - target_amount else target_amount - next_amount;

        if (next_diff < initial_diff) {
            let rebate_bps = tax_basis_points * initial_diff / target_amount;
            return if(rebate_bps > fee_basis_points) 0 else fee_basis_points - rebate_bps;
        };

        let average_diff = (initial_diff + next_diff) / 2;
        if (average_diff > target_amount) {
            average_diff = target_amount;
        };
        let tax_bps = tax_basis_points * average_diff / target_amount;
        fee_basis_points + tax_bps;
    }
}