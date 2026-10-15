// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {POEDBToken} from "../src/POEDBToken.sol";

/// @dev Drives the token with six actors plus two sinks nothing can spend from: the token contract
/// itself and an address that never acts. Alongside the successful calls it makes every call the
/// token must refuse, through low-level calls so the sequence continues, and checks each refusal
/// changed nothing. Ghost variables track what every address should hold and how much has flowed.
contract OpenHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 * 10 ** 18;

    POEDBToken public immutable token;
    address[6] public actors;
    address public immutable stranger;

    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public sunkToToken;
    uint256 public sunkToStranger;
    uint256 public totalMoved;
    uint256 public refusals;
    uint256 public successes;

    constructor(POEDBToken token_) {
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("open actor ", vm.toString(i)));
        }
        stranger = makeAddr("never acts");
        expectedBalance[actors[0]] = SUPPLY;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    // ------------------------------------------------------------------------------ successes

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        totalMoved += amount;
        ++successes;
    }

    function transferToSink(uint256 fromSeed, bool toTokenContract, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        // Keep sinks small so the actors stay funded through long sequences.
        uint256 amount = bound(amountSeed, 0, expectedBalance[from] / 1_000);
        address to = toTokenContract ? address(token) : stranger;
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        if (toTokenContract) sunkToToken += amount;
        else sunkToStranger += amount;
        totalMoved += amount;
        ++successes;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // One call in eight grants the unlimited allowance so that path is exercised often.
        uint256 amount = amountSeed % 8 == 0 ? type(uint256).max : amountSeed;
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
        ++successes;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 amount = bound(amountSeed, 0, _min(allowed, expectedBalance[owner]));
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        totalMoved += amount;
        ++successes;
    }

    // ------------------------------------------------------------------------------- refusals

    function _expectRefusal(address caller, bytes memory data, bytes memory expectedError) private {
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(data);
        assertFalse(ok, "the token accepted a call it must refuse");
        assertEq(ret, expectedError, "the token refused for a different reason");
        ++refusals;
    }

    function refuseOverspend(uint256 fromSeed, uint256 toSeed, uint256 excessSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = expectedBalance[from];
        uint256 amount = held + bound(excessSeed, 1, type(uint256).max - held);
        _expectRefusal(
            from,
            abi.encodeCall(token.transfer, (to, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount)
        );
    }

    function refuseOverAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excessSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        if (allowed == type(uint256).max) {
            // Unlimited allowance cannot be exceeded; the balance is the only limit.
            uint256 held = expectedBalance[owner];
            uint256 amount = held + bound(excessSeed, 1, type(uint256).max - held);
            _expectRefusal(
                spender,
                abi.encodeCall(token.transferFrom, (owner, to, amount)),
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount)
            );
            return;
        }
        uint256 over = allowed + bound(excessSeed, 1, type(uint256).max - allowed);
        _expectRefusal(
            spender,
            abi.encodeCall(token.transferFrom, (owner, to, over)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, over)
        );
    }

    function refuseBalanceShortfallWithAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 excessSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 held = expectedBalance[owner];
        if (allowed <= held) return;
        uint256 amount = held + bound(excessSeed, 1, allowed - held);
        _expectRefusal(
            spender,
            abi.encodeCall(token.transferFrom, (owner, owner, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount)
        );
    }

    function refuseTransferToZero(uint256 fromSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        _expectRefusal(
            from,
            abi.encodeCall(token.transfer, (address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
        );
    }

    function refuseApproveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        _expectRefusal(
            owner,
            abi.encodeCall(token.approve, (address(0), amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))
        );
    }

    function refuseSpendingFromSinks(uint256 spenderSeed, uint256 amountSeed) external {
        address spender = _actor(spenderSeed);
        uint256 amount = bound(amountSeed, 1, type(uint256).max);
        _expectRefusal(
            spender,
            abi.encodeCall(token.transferFrom, (address(token), spender, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount)
        );
        _expectRefusal(
            spender,
            abi.encodeCall(token.transferFrom, (stranger, spender, amount)),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount)
        );
    }

    function refuseMintAndBurn(uint256 callerSeed, uint256 amount) external {
        address caller = _actor(callerSeed);
        address victim = _actor((callerSeed % actors.length) + 1);
        bytes[4] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", caller, amount),
            abi.encodeWithSignature("burn(uint256)", amount),
            abi.encodeWithSignature("burnFrom(address,uint256)", victim, amount),
            abi.encodeWithSignature("seize(address)", victim)
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(caller);
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok, "a mint, burn or seize selector was accepted");
            ++refusals;
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract POEDBTokenOpenInvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;

    POEDBToken private token;
    OpenHandler private handler;

    function setUp() public {
        token = new POEDBToken();
        handler = new OpenHandler(token);
        token.transfer(handler.actors(0), SUPPLY);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferToSink.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.transferFrom.selector;
        selectors[4] = handler.refuseOverspend.selector;
        selectors[5] = handler.refuseOverAllowance.selector;
        selectors[6] = handler.refuseBalanceShortfallWithAllowance.selector;
        selectors[7] = handler.refuseTransferToZero.selector;
        selectors[8] = handler.refuseApproveZeroSpender.selector;
        selectors[9] = handler.refuseSpendingFromSinks.selector;
        selectors[10] = handler.refuseMintAndBurn.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _actorSum() private view returns (uint256 sum) {
        for (uint256 i; i < 6; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
    }

    /// @dev Fixed supply: nothing in any sequence mints or burns.
    function invariant_totalSupplyIsConstant() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    /// @dev Everything the actors hold plus everything sunk is exactly the supply; nothing leaks elsewhere.
    function invariant_actorsAndSinksAccountForTheWholeSupply() public view {
        assertEq(_actorSum() + handler.sunkToToken() + handler.sunkToStranger(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// @dev Each actor's balance matches the ghost ledger built from the successful calls alone,
    /// so no refused call moved anything.
    function invariant_balancesMatchTheGhostLedger() public view {
        for (uint256 i; i < 6; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor));
            assertLe(token.balanceOf(actor), SUPPLY);
        }
    }

    /// @dev Tokens sent to the contract itself or to an inert address stay there: no recovery path exists.
    function invariant_sinksOnlyGrow() public view {
        assertEq(token.balanceOf(address(token)), handler.sunkToToken());
        assertEq(token.balanceOf(handler.stranger()), handler.sunkToStranger());
    }

    /// @dev Allowances change only through approve by the owner or a finite spend by the spender.
    function invariant_allowancesMatchTheGhostLedger() public view {
        for (uint256 i; i < 6; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < 6; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender));
            }
            assertEq(token.allowance(address(token), owner), 0);
            assertEq(token.allowance(handler.stranger(), owner), 0);
        }
    }

    /// @dev The amount moved is bounded by what was ever available to move, per call at most the supply.
    function invariant_movedVolumeIsBoundedBySuccessfulCalls() public view {
        assertLe(handler.totalMoved(), handler.successes() * SUPPLY);
    }

    /// @dev The sequence exercised refusals as well as successes once it is long enough to have done so.
    function invariant_refusalsWereExercised() public view {
        if (handler.successes() + handler.refusals() >= 64) {
            assertGt(handler.refusals(), 0, "no refusal path was reached");
        }
    }
}
