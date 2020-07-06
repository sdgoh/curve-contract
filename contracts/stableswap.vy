# (c) Curve.Fi, 2020
#
# TODO
# + Change token contract name by admin
# + Ramp A
# + Dynamic fees
# + Aave wrap/unwrap
# + Admin fees Aave-compatible - balances work differently
# * Make one-coin-removal functionality native
# * Tests

import ERC20m as ERC20m
from vyper.interfaces import ERC20


# Tether transfer-only ABI
contract USDT:
    def transfer(_to: address, _value: uint256): modifying
    def transferFrom(_from: address, _to: address, _value: uint256): modifying

contract aToken:
    def redeem(_amount: uint256): modifying


# This can (and needs to) be changed at compile time
N_COINS: constant(int128) = ___N_COINS___  # <- change

ZERO256: constant(uint256) = 0  # This hack is really bad XXX
ZEROS: constant(uint256[N_COINS]) = ___N_ZEROS___  # <- change

# Flag "ERC20s" which don't return from transfer() and transferFrom()
TETHERED: constant(bool[N_COINS]) = ___TETHERED___

FEE_DENOMINATOR: constant(uint256) = 10 ** 10
LENDING_PRECISION: constant(uint256) = 10 ** 18
PRECISION: constant(uint256) = 10 ** 18  # The precision to convert to
PRECISION_MUL: constant(uint256[N_COINS]) = ___PRECISION_MUL___
# Example:
# PRECISION_MUL: constant(uint256[N_COINS]) = [
#     PRECISION / convert(PRECISION, uint256),  # DAI
#     PRECISION / convert(10 ** 6, uint256),   # USDC
#     PRECISION / convert(10 ** 6, uint256)]   # USDT


admin_actions_delay: constant(uint256) = 3 * 86400
min_ramp_time: constant(uint256) = 86400

# Events
TokenExchange: event({buyer: indexed(address), sold_id: int128, tokens_sold: uint256, bought_id: int128, tokens_bought: uint256})
TokenExchangeUnderlying: event({buyer: indexed(address), sold_id: int128, tokens_sold: uint256, bought_id: int128, tokens_bought: uint256})
AddLiquidity: event({provider: indexed(address), token_amounts: uint256[N_COINS], fees: uint256[N_COINS], invariant: uint256, token_supply: uint256})
RemoveLiquidity: event({provider: indexed(address), token_amounts: uint256[N_COINS], fees: uint256[N_COINS], token_supply: uint256})
RemoveLiquidityImbalance: event({provider: indexed(address), token_amounts: uint256[N_COINS], fees: uint256[N_COINS], invariant: uint256, token_supply: uint256})
RemoveLiquidityOne: event({provider: indexed(address), token_amount: uint256, coin_amount: uint256})
CommitNewAdmin: event({deadline: indexed(timestamp), admin: indexed(address)})
NewAdmin: event({admin: indexed(address)})

CommitNewFee: event({deadline: indexed(timestamp), fee: uint256, admin_fee: uint256, offpeg_fee_multiplier: uint256})
NewFee: event({fee: uint256, admin_fee: uint256, offpeg_fee_multiplier: uint256})
RampA: event({old_A: uint256, new_A: uint256, initial_time: timestamp, future_time: timestamp})
StopRampA: event({A: uint256, t: timestamp})

coins: public(address[N_COINS])
underlying_coins: public(address[N_COINS])
admin_balances: public(uint256[N_COINS])
fee: public(uint256)  # fee * 1e10
offpeg_fee_multiplier: public(uint256)  # * 1e10
admin_fee: public(uint256)  # admin_fee * 1e10

aave_lending_pool: address
aave_referral: uint256

max_admin_fee: constant(uint256) = 5 * 10 ** 9
max_fee: constant(uint256) = 5 * 10 ** 9
max_A: constant(uint256) = 10 ** 6

owner: public(address)
token: ERC20m

admin_actions_deadline: public(timestamp)
transfer_ownership_deadline: public(timestamp)
future_fee: public(uint256)
future_admin_fee: public(uint256)
future_offpeg_fee_multiplier: public(uint256)  # * 1e10
future_owner: public(address)

initial_A: public(uint256)
future_A: public(uint256)
initial_A_time: public(timestamp)
future_A_time: public(timestamp)

kill_deadline: timestamp
kill_deadline_dt: constant(uint256) = 2 * 30 * 86400
is_killed: bool


@public
def __init__(_coins: address[N_COINS],
             _underlying_coins: address[N_COINS],
             _pool_token: address,
             _aave_lending_pool: address,
             _A: uint256, _fee: uint256):
    """
    _coins: Addresses of ERC20 conracts of coins (c-tokens) involved
    _pool_token: Address of the token representing LP share
    _A: Amplification coefficient multiplied by n * (n - 1)
    _fee: Fee to charge for exchanges
    """
    for i in range(N_COINS):
        assert _coins[i] != ZERO_ADDRESS
        assert _underlying_coins[i] != ZERO_ADDRESS
        self.admin_balances[i] = 0
    self.coins = _coins
    self.underlying_coins = _underlying_coins
    self.initial_A = _A
    self.future_A = _A
    self.initial_A_time = 0
    self.future_A_time = 0
    self.fee = _fee
    self.offpeg_fee_multiplier = 0
    self.admin_fee = 0
    self.owner = msg.sender
    self.kill_deadline = block.timestamp + kill_deadline_dt
    self.is_killed = False
    self.token = ERC20m(_pool_token)
    self.aave_lending_pool = _aave_lending_pool
    self.aave_referral = 0


@private
def aave_deposit(_reserve: address, _amount: uint256, _referralCode: uint256):
    # def deposit(_reserve: address, _amount: uint256, _referralCode: uint16): modifying
    # Vyper cannot automatically make this ABI until uint16 arrives
    assert _referralCode < 2 ** 16

    data: bytes[100] = concat(
        b'\xd2\xd0\xe0\x66',                        # ABI MethodID
        convert(_reserve, bytes32),                 # address
        convert(_amount, bytes32),                  # uint256
        convert(_referralCode, bytes32)             # uint16
    )
    raw_call(self.aave_lending_pool, data)


@constant
@private
def _A() -> uint256:
    """
    Handle ramping A up or down
    """
    t1: timestamp = self.future_A_time
    A1: uint256 = self.future_A

    if block.timestamp < t1:
        A0: uint256 = self.initial_A
        t0: timestamp = self.initial_A_time
        # Expressions in uint256 cannot have negative numbers, thus "if"
        if A1 > A0:
            return A0 + (A1 - A0) * (block.timestamp - t0) / (t1 - t0)
        else:
            return A0 - (A0 - A1) * (block.timestamp - t0) / (t1 - t0)

    else:  # when t1 == 0 or block.timestamp >= t1
        return A1


@constant
@public
def A() -> uint256:
    return self._A()


@constant
@private
def _dynamic_fee(xpi: uint256, xpj: uint256, _fee: uint256, _feemul: uint256) -> uint256:
    if _feemul <= FEE_DENOMINATOR:
        return _fee
    else:
        xps2: uint256 = xpi + xpj
        xps2 *= xps2  # Doing just ** 2 can overflow apparently
        return (_feemul * _fee) / (
            (_feemul - FEE_DENOMINATOR) * 4 * xpi * xpj / xps2 + \
            FEE_DENOMINATOR)


@constant
@public
def dynamic_fee(i: int128, j: int128) -> uint256:
    precisions: uint256[N_COINS] = PRECISION_MUL
    xpi: uint256 = (ERC20(self.coins[i]).balanceOf(self) - self.admin_balances[i]) * precisions[i]
    xpj: uint256 = (ERC20(self.coins[j]).balanceOf(self) - self.admin_balances[j]) * precisions[j]
    return self._dynamic_fee(xpi, xpj, self.fee, self.offpeg_fee_multiplier)


@constant
@public
def balances(i: int128) -> uint256:
    return ERC20(self.coins[i]).balanceOf(self) - self.admin_balances[i]


@constant
@private
def _balances() -> uint256[N_COINS]:
    result: uint256[N_COINS] = ZEROS
    for i in range(N_COINS):
        result[i] = ERC20(self.coins[i]).balanceOf(self) - self.admin_balances[i]
    return result


@private
@constant
def get_D(xp: uint256[N_COINS], amp: uint256) -> uint256:
    """
    D invariant calculation in non-overflowing integer operations
    iteratively

    A * sum(x_i) * n**n + D = A * D * n**n + D**(n+1) / (n**n * prod(x_i))

    Converging solution:
    D[j+1] = (A * n**n * sum(x_i) - D[j]**(n+1) / (n**n prod(x_i))) / (A * n**n - 1)
    """
    S: uint256 = 0

    for _x in xp:
        S += _x
    if S == 0:
        return 0

    Dprev: uint256 = 0
    D: uint256 = S
    Ann: uint256 = amp * N_COINS
    for _i in range(255):
        D_P: uint256 = D
        for _x in xp:
            D_P = D_P * D / (_x * N_COINS + 1)  # +1 is to prevent /0
        Dprev = D
        D = (Ann * S + D_P * N_COINS) * D / ((Ann - 1) * D + (N_COINS + 1) * D_P)
        # Equality with the precision of 1
        if D > Dprev:
            if D - Dprev <= 1:
                break
        else:
            if Dprev - D <= 1:
                break
    return D


@private
@constant
def get_D_precisions(_balances: uint256[N_COINS], amp: uint256) -> uint256:
    xp: uint256[N_COINS] = PRECISION_MUL
    for i in range(N_COINS):
        xp[i] *= _balances[i]
    return self.get_D(xp, amp)


@public
@constant
def get_virtual_price() -> uint256:
    """
    Returns portfolio virtual price (for calculating profit)
    scaled up by 1e18
    """
    D: uint256 = self.get_D_precisions(self._balances(), self._A())
    # D is in the units similar to DAI (e.g. converted to precision 1e18)
    # When balanced, D = n * x_u - total virtual value of the portfolio
    token_supply: uint256 = self.token.totalSupply()
    return D * PRECISION / token_supply


@public
@constant
def calc_token_amount(amounts: uint256[N_COINS], deposit: bool) -> uint256:
    """
    Simplified method to calculate addition or reduction in token supply at
    deposit or withdrawal without taking fees into account (but looking at
    slippage).
    Needed to prevent front-running, not for precise calculations!
    """
    _balances: uint256[N_COINS] = self._balances()
    amp: uint256 = self._A()
    D0: uint256 = self.get_D_precisions(_balances, amp)
    for i in range(N_COINS):
        if deposit:
            _balances[i] += amounts[i]
        else:
            _balances[i] -= amounts[i]
    D1: uint256 = self.get_D_precisions(_balances, amp)
    token_amount: uint256 = self.token.totalSupply()
    diff: uint256 = 0
    if deposit:
        diff = D1 - D0
    else:
        diff = D0 - D1
    return diff * token_amount / D0


@public
@nonreentrant('lock')
def add_liquidity(amounts: uint256[N_COINS], min_mint_amount: uint256):
    # Amounts is amounts of c-tokens
    assert not self.is_killed

    tethered: bool[N_COINS] = TETHERED
    fees: uint256[N_COINS] = ZEROS
    _fee: uint256 = self.fee * N_COINS / (4 * (N_COINS - 1))
    _feemul: uint256 = self.offpeg_fee_multiplier
    _admin_fee: uint256 = self.admin_fee
    amp: uint256 = self._A()

    token_supply: uint256 = self.token.totalSupply()
    # Initial invariant
    D0: uint256 = 0
    old_balances: uint256[N_COINS] = self._balances()
    if token_supply > 0:
        D0 = self.get_D_precisions(old_balances, amp)
    new_balances: uint256[N_COINS] = old_balances

    for i in range(N_COINS):
        if token_supply == 0:
            assert amounts[i] > 0
        new_balances[i] = old_balances[i] + amounts[i]

    # Invariant after change
    D1: uint256 = self.get_D_precisions(new_balances, amp)
    assert D1 > D0

    ys: uint256 = (D0 + D1) / N_COINS

    # We need to recalculate the invariant accounting for fees
    # to calculate fair user's share
    D2: uint256 = D1
    if token_supply > 0:
        # Only account for fees if we are not the first to deposit
        for i in range(N_COINS):
            ideal_balance: uint256 = D1 * old_balances[i] / D0
            difference: uint256 = 0
            if ideal_balance > new_balances[i]:
                difference = ideal_balance - new_balances[i]
            else:
                difference = new_balances[i] - ideal_balance
            xs: uint256 = old_balances[i] + new_balances[i]
            fees[i] = self._dynamic_fee(xs, ys, _fee, _feemul) * difference / FEE_DENOMINATOR
            if _admin_fee > 0:
                self.admin_balances[i] += fees[i] * _admin_fee / FEE_DENOMINATOR
            new_balances[i] -= fees[i]
        D2 = self.get_D_precisions(new_balances, amp)

    # Calculate, how much pool tokens to mint
    mint_amount: uint256 = 0
    if token_supply == 0:
        mint_amount = D1  # Take the dust if there was any
    else:
        mint_amount = token_supply * (D2 - D0) / D0

    assert mint_amount >= min_mint_amount, "Slippage screwed you"

    # Take coins from the sender
    for i in range(N_COINS):
        assert_modifiable(
            ERC20(self.coins[i]).transferFrom(msg.sender, self, amounts[i]))

    # Mint pool tokens
    self.token.mint(msg.sender, mint_amount)

    log.AddLiquidity(msg.sender, amounts, fees, D1, token_supply + mint_amount)


@private
@constant
def get_y(i: int128, j: int128, x: uint256, xp: uint256[N_COINS]) -> uint256:
    """
    Calculate x[j] if one makes x[i] = x

    Done by solving quadratic equation iteratively.
    x_1**2 + x1 * (sum' - (A*n**n - 1) * D / (A * n**n)) = D ** (n + 1) / (n ** (2 * n) * prod' * A)
    x_1**2 + b*x_1 = c

    x_1 = (x_1**2 + c) / (2*x_1 + b)
    """
    # x in the input is converted to the same price/precision

    assert (i != j) and (i >= 0) and (j >= 0) and (i < N_COINS) and (j < N_COINS)

    amp: uint256 = self._A()
    D: uint256 = self.get_D(xp, amp)
    c: uint256 = D
    S_: uint256 = 0
    Ann: uint256 = amp * N_COINS

    _x: uint256 = 0
    for _i in range(N_COINS):
        if _i == i:
            _x = x
        elif _i != j:
            _x = xp[_i]
        else:
            continue
        S_ += _x
        c = c * D / (_x * N_COINS)
    c = c * D / (Ann * N_COINS)
    b: uint256 = S_ + D / Ann  # - D
    y_prev: uint256 = 0
    y: uint256 = D
    for _i in range(255):
        y_prev = y
        y = (y*y + c) / (2 * y + b - D)
        # Equality with the precision of 1
        if y > y_prev:
            if y - y_prev <= 1:
                break
        else:
            if y_prev - y <= 1:
                break
    return y


@private
@constant
def get_y_D(A: uint256, i: int128, xp: uint256[N_COINS], D: uint256) -> uint256:
    """
    Calculate x[i] if one reduces D from being calculated for xp to D

    Done by solving quadratic equation iteratively.
    x_1**2 + x1 * (sum' - (A*n**n - 1) * D / (A * n**n)) = D ** (n + 1) / (n ** (2 * n) * prod' * A)
    x_1**2 + b*x_1 = c

    x_1 = (x_1**2 + c) / (2*x_1 + b)
    """
    # x in the input is converted to the same price/precision

    assert (i >= 0) and (i < N_COINS)

    c: uint256 = D
    S_: uint256 = 0
    Ann: uint256 = A * N_COINS

    _x: uint256 = 0
    for _i in range(N_COINS):
        if _i != i:
            _x = xp[_i]
        else:
            continue
        S_ += _x
        c = c * D / (_x * N_COINS)
    c = c * D / (Ann * N_COINS)
    b: uint256 = S_ + D / Ann
    y_prev: uint256 = 0
    y: uint256 = D
    for _i in range(255):
        y_prev = y
        y = (y*y + c) / (2 * y + b - D)
        # Equality with the precision of 1
        if y > y_prev:
            if y - y_prev <= 1:
                break
        else:
            if y_prev - y <= 1:
                break
    return y


@private
@constant
def _calc_withdraw_one_coin(_token_amount: uint256, i: int128) -> uint256:
    # First, need to calculate
    # * Get current D
    # * Solve Eqn against y_i for D - _token_amount
    A: uint256 = self._A()
    _fee: uint256 = self.fee * N_COINS / (4 * (N_COINS - 1))
    feemul: uint256 = self.offpeg_fee_multiplier
    precisions: uint256[N_COINS] = PRECISION_MUL
    total_supply: uint256 = self.token.totalSupply()

    xp: uint256[N_COINS] = self._balances()
    S: uint256 = 0
    for j in range(N_COINS):
        xp[j] *= precisions[j]
        S += xp[j]

    D0: uint256 = self.get_D(xp, A)
    D1: uint256 = D0 - _token_amount * D0 / total_supply
    xp_reduced: uint256[N_COINS] = xp
    ys: uint256 = (D0 + D1) / (2 * N_COINS)

    new_y: uint256 = self.get_y_D(A, i, xp, D1)

    for j in range(N_COINS):
        dx_expected: uint256 = 0
        xavg: uint256 = 0
        if j == i:
            dx_expected = xp[j] * D1 / D0 - new_y
            xavg = (xp[j] + new_y) / 2
        else:
            dx_expected = xp[j] - xp[j] * D1 / D0
            xavg = xp[j]
        xp_reduced[j] -= self._dynamic_fee(xavg, ys, _fee, feemul) * dx_expected / FEE_DENOMINATOR

    dy: uint256 = xp_reduced[i] - self.get_y_D(A, i, xp_reduced, D1)
    dy = dy / precisions[i]

    return dy


@public
@constant
def calc_withdraw_one_coin(_token_amount: uint256, i: int128) -> uint256:
    return self._calc_withdraw_one_coin(_token_amount, i)


@public
@nonreentrant('lock')
def remove_liquidity_one_coin(_token_amount: uint256, i: int128, min_uamount: uint256):
    """
    Remove _amount of liquidity all in a form of coin i
    """
    dy: uint256 = self._calc_withdraw_one_coin(_token_amount, i)
    assert dy >= min_uamount, "Not enough coins removed"

    self.token.burnFrom(msg.sender, _token_amount)
    assert_modifiable(ERC20(self.coins[i]).transfer(msg.sender, dy))

    log.RemoveLiquidityOne(msg.sender, _token_amount, dy)


@public
@constant
def get_dy(i: int128, j: int128, dx: uint256) -> uint256:
    # dx and dy in c-units
    precisions: uint256[N_COINS] = PRECISION_MUL
    xp: uint256[N_COINS] = self._balances()
    for k in range(N_COINS):
        xp[k] *= precisions[k]

    x: uint256 = xp[i] + dx * precisions[i]
    y: uint256 = self.get_y(i, j, x, xp)
    dy: uint256 = (xp[j] - y) / precisions[j]
    _fee: uint256 = self._dynamic_fee(
            (xp[i] + x) / 2, (xp[j] + y) / 2, self.fee, self.offpeg_fee_multiplier
        ) * dy / FEE_DENOMINATOR
    return dy - _fee


@private
def _exchange(i: int128, j: int128, dx: uint256) -> uint256:
    assert not self.is_killed
    # dx and dy are in c-tokens

    xp: uint256[N_COINS] = self._balances()
    precisions: uint256[N_COINS] = PRECISION_MUL
    for k in range(N_COINS):
        xp[k] *= precisions[k]

    x: uint256 = xp[i] + dx * precisions[i]
    y: uint256 = self.get_y(i, j, x, xp)
    dy: uint256 = xp[j] - y
    dy_fee: uint256 = dy * self._dynamic_fee(
            (xp[i] + x) / 2, (xp[j] + y) / 2, self.fee, self.offpeg_fee_multiplier
        ) / FEE_DENOMINATOR
    dy_admin_fee: uint256 = dy_fee * self.admin_fee / FEE_DENOMINATOR
    if dy_admin_fee > 0:
        self.admin_balances[j] += dy_admin_fee / precisions[j]

    _dy: uint256 = (dy - dy_fee) / precisions[j]

    return _dy


@public
@nonreentrant('lock')
def exchange(i: int128, j: int128, dx: uint256, min_dy: uint256):
    dy: uint256 = self._exchange(i, j, dx)
    assert dy >= min_dy, "Exchange resulted in fewer coins than expected"

    assert_modifiable(ERC20(self.coins[i]).transferFrom(msg.sender, self, dx))
    assert_modifiable(ERC20(self.coins[j]).transfer(msg.sender, dy))

    log.TokenExchange(msg.sender, i, dx, j, dy)


@public
@nonreentrant('lock')
def exchange_underlying(i: int128, j: int128, dx: uint256, min_dy: uint256):
    dy: uint256 = self._exchange(i, j, dx)
    assert dy >= min_dy, "Exchange resulted in fewer coins than expected"
    tethered: bool[N_COINS] = TETHERED

    u_coin_i: address = self.underlying_coins[i]
    u_coin_j: address = self.underlying_coins[j]
    coin_j: address = self.coins[j]

    if tethered[i]:
        USDT(u_coin_i).transferFrom(msg.sender, self, dx)
    else:
        assert_modifiable(ERC20(u_coin_i).transferFrom(msg.sender, self, dx))
    ERC20(u_coin_i).approve(self.aave_lending_pool, dx)
    self.aave_deposit(u_coin_i, dx, self.aave_referral)
    aToken(coin_j).redeem(dy)
    if tethered[j]:
        USDT(u_coin_j).transfer(msg.sender, dy)
    else:
        assert_modifiable(ERC20(u_coin_j).transfer(msg.sender, dy))

    log.TokenExchangeUnderlying(msg.sender, i, dx, j, dy)


@public
@nonreentrant('lock')
def remove_liquidity(_amount: uint256, min_amounts: uint256[N_COINS]):
    total_supply: uint256 = self.token.totalSupply()
    fees: uint256[N_COINS] = ZEROS
    amounts: uint256[N_COINS] = self._balances()

    for i in range(N_COINS):
        value: uint256 = amounts[i] * _amount / total_supply
        assert value >= min_amounts[i], "Withdrawal resulted in fewer coins than expected"
        amounts[i] = value
        assert_modifiable(ERC20(self.coins[i]).transfer(msg.sender, value))

    self.token.burnFrom(msg.sender, _amount)  # Will raise if not enough

    log.RemoveLiquidity(msg.sender, amounts, fees, total_supply - _amount)


@public
@nonreentrant('lock')
def remove_liquidity_imbalance(amounts: uint256[N_COINS], max_burn_amount: uint256):
    assert not self.is_killed

    token_supply: uint256 = self.token.totalSupply()
    assert token_supply > 0
    _fee: uint256 = self.fee * N_COINS / (4 * (N_COINS - 1))
    _feemul: uint256 = self.offpeg_fee_multiplier
    _admin_fee: uint256 = self.admin_fee
    amp: uint256 = self._A()

    old_balances: uint256[N_COINS] = self._balances()
    new_balances: uint256[N_COINS] = old_balances
    D0: uint256 = self.get_D_precisions(old_balances, amp)
    for i in range(N_COINS):
        new_balances[i] -= amounts[i]
    D1: uint256 = self.get_D_precisions(new_balances, amp)
    ys: uint256 = (D0 + D1) / N_COINS
    fees: uint256[N_COINS] = ZEROS
    for i in range(N_COINS):
        ideal_balance: uint256 = D1 * old_balances[i] / D0
        difference: uint256 = 0
        if ideal_balance > new_balances[i]:
            difference = ideal_balance - new_balances[i]
        else:
            difference = new_balances[i] - ideal_balance
        xs: uint256 = new_balances[i] + old_balances[i]
        fees[i] = self._dynamic_fee(xs, ys, _fee, _feemul) * difference / FEE_DENOMINATOR
        if _admin_fee > 0:
            self.admin_balances[i] += fees[i] * _admin_fee / FEE_DENOMINATOR
        new_balances[i] -= fees[i]
    D2: uint256 = self.get_D_precisions(new_balances, amp)

    token_amount: uint256 = (D0 - D2) * token_supply / D0
    assert token_amount > 0
    assert token_amount <= max_burn_amount, "Slippage screwed you"

    for i in range(N_COINS):
        assert_modifiable(ERC20(self.coins[i]).transfer(msg.sender, amounts[i]))
    self.token.burnFrom(msg.sender, token_amount)  # Will raise if not enough

    log.RemoveLiquidityImbalance(msg.sender, amounts, fees, D1, token_supply - token_amount)


### Admin functions ###
@public
def ramp_A(_future_A: uint256, _future_time: timestamp):
    assert msg.sender == self.owner
    assert _future_time >= block.timestamp + min_ramp_time

    _initial_A: uint256 = self._A()
    self.initial_A = _initial_A
    self.future_A = _future_A
    self.initial_A_time = block.timestamp
    self.future_A_time = _future_time

    log.RampA(_initial_A, _future_A, block.timestamp, _future_time)


@public
def stop_ramp_A():
    assert msg.sender == self.owner

    current_A: uint256 = self._A()
    self.initial_A = current_A
    self.future_A = current_A
    self.initial_A_time = 0
    self.future_A_time = 0

    log.StopRampA(current_A, block.timestamp)


@public
def commit_new_fee(new_fee: uint256, new_admin_fee: uint256, new_offpeg_fee_multiplier: uint256):
    assert msg.sender == self.owner
    assert self.admin_actions_deadline == 0
    assert new_admin_fee <= max_admin_fee
    assert new_fee <= max_fee
    assert new_offpeg_fee_multiplier * new_fee <= max_fee * FEE_DENOMINATOR

    _deadline: timestamp = block.timestamp + admin_actions_delay
    self.admin_actions_deadline = _deadline
    self.future_fee = new_fee
    self.future_admin_fee = new_admin_fee
    self.future_offpeg_fee_multiplier = new_offpeg_fee_multiplier

    log.CommitNewFee(_deadline, new_fee, new_admin_fee, new_offpeg_fee_multiplier)


@public
def apply_new_fee():
    assert msg.sender == self.owner
    assert self.admin_actions_deadline <= block.timestamp\
        and self.admin_actions_deadline > 0

    self.admin_actions_deadline = 0
    _fee: uint256 = self.future_fee
    _admin_fee: uint256 = self.future_admin_fee
    _fml: uint256 = self.future_offpeg_fee_multiplier
    self.fee = _fee
    self.admin_fee = _admin_fee
    self.offpeg_fee_multiplier = _fml

    log.NewFee(_fee, _admin_fee, _fml)


@public
def revert_new_parameters():
    assert msg.sender == self.owner

    self.admin_actions_deadline = 0


@public
def commit_transfer_ownership(_owner: address):
    assert msg.sender == self.owner
    assert self.transfer_ownership_deadline == 0

    _deadline: timestamp = block.timestamp + admin_actions_delay
    self.transfer_ownership_deadline = _deadline
    self.future_owner = _owner

    log.CommitNewAdmin(_deadline, _owner)


@public
def apply_transfer_ownership():
    assert msg.sender == self.owner
    assert block.timestamp >= self.transfer_ownership_deadline\
        and self.transfer_ownership_deadline > 0

    self.transfer_ownership_deadline = 0
    _owner: address = self.future_owner
    self.owner = _owner

    log.NewAdmin(_owner)


@public
def revert_transfer_ownership():
    assert msg.sender == self.owner

    self.transfer_ownership_deadline = 0


@public
def withdraw_admin_fees():
    assert msg.sender == self.owner
    _precisions: uint256[N_COINS] = PRECISION_MUL

    for i in range(N_COINS):
        c: address = self.coins[i]
        value: uint256 = self.admin_balances[i]
        if value > 0:
            assert_modifiable(ERC20(c).transfer(msg.sender, value))
            self.admin_balances[i] = 0


@public
def donate_admin_fees():
    """
    Just in case admin balances somehow become higher than total (rounding error?)
    this can be used to fix the state, too
    """
    assert msg.sender == self.owner
    self.admin_balances = ZEROS


@public
def kill_me():
    assert msg.sender == self.owner
    assert self.kill_deadline > block.timestamp
    self.is_killed = True


@public
def unkill_me():
    assert msg.sender == self.owner
    self.is_killed = False


@public
def set_aave_referral(referral_code: uint256):
    assert msg.sender == self.owner
    assert referral_code < 2 ** 16  # uint16 check
    self.aave_referral = referral_code