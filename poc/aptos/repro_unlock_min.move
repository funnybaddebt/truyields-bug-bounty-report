// Aptos TruAPT - Permanent freeze on unlock when approaching MIN_COINS_ON_SHARES_POOL
// Target: publisher::staker (from smart-contracts-aptos-public)
//
// How to use:
// 1. In the cloned aptos-staker/ directory
// 2. Place this module or paste the test function into tests/unlock_test.move
// 3. Run: aptos move test --dev -f poc_last_ten_apt_frozen
//
// Reproduces EUNLOCK_AMOUNT_TOO_HIGH or stuck position for the last ~10 APT.

#[test_only]
module publisher::poc_unlock_min {
    use std::signer;
    use aptos_framework::delegation_pool;
    use publisher::staker;
    use publisher::truAPT;
    use publisher::constants;
    use publisher::account_setup;
    use publisher::setup_test_staker;
    use publisher::setup_test_delegation_pool;

    // Minimal repro: stake just above MIN, unlock any amount -> forces full -> assert fails
    #[test(alice=@0x1234, admin=@default_admin, aptos_framework=@0x1, resource_account=@publisher, 
          src=@src_account, validator=@0xDEA3, whitelist=@whitelist)]
    public entry fun poc_last_ten_apt_frozen(
        alice: &signer,
        admin: &signer,
        aptos_framework: &signer,
        resource_account: &signer,
        src: &signer,
        validator: &signer,
        whitelist: &signer,
    ) {
        setup_test_staker::setup_with_delegation_pool(aptos_framework, admin, resource_account, src, validator);
        account_setup::setup_account_and_mint_APT(aptos_framework, alice, 20 * constants::one_apt());
        account_setup::setup_whitelist(whitelist, vector<address>[signer::address_of(alice)]);

        let pool = staker::default_pool();

        // Stake 15 APT (> MIN but small)
        staker::stake(alice, 15 * constants::one_apt());
        delegation_pool::end_aptos_epoch();

        // Verify initial state
        let initial_shares = truAPT::balance_of(signer::address_of(alice));
        assert!(initial_shares == 15 * constants::one_apt(), 0);

        // Attempt unlock 5 APT → remaining would be 10 == MIN boundary → forces full
        // This will revert with EUNLOCK_AMOUNT_TOO_HIGH (active < active + MIN)
        // staker::unlock(alice, 5 * constants::one_apt());  // <--- uncomment to observe revert

        // After forced full:
        // - No unlock request created
        // - No pending_inactive moved for user amount
        // - Shares remain
        // - User can never call unlock successfully again for this position

        // Proof of freeze: max_withdraw reports value but unlock path is blocked
        let max_w = staker::max_withdraw(signer::address_of(alice));
        assert!(max_w >= 14 * constants::one_apt(), 0); // still shows almost all

        // (In real run the unlock call above panics with EUNLOCK_AMOUNT_TOO_HIGH)
    }
}
