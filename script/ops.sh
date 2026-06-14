#!/usr/bin/env bash
# 协议操作脚本
#
# 用法:
#   ./script/ops.sh mint     <account> <asset> <amount>          # deployer mint token 给某账户
#   ./script/ops.sh deposit  <account> <asset> <amount>          # 存款
#   ./script/ops.sh withdraw <account> <asset> <amount|max>      # 提款
#   ./script/ops.sh borrow   <account> <col> <colAmt> <debt> <debtAmt>  # 开仓借款
#   ./script/ops.sh repay    <account> <col> <debt> <amount|max> # 还款
#   ./script/ops.sh add-col  <account> <col> <debt> <amount>     # 追加抵押物
#   ./script/ops.sh with-col <account> <col> <debt> <amount|max> # 提取抵押物
#   ./script/ops.sh close    <account> <col> <debt>              # 还清债务并提走抵押物
#   ./script/ops.sh reset-all                                    # 关闭所有仓位+提走所有存款
#
# account: deployer | alice | bob | charlie
# asset:   usdc | eurc | weth
# amount:  数字 (如 500 表示 500 USDC, 0.12 表示 0.12 WETH) 或 max
#
# 示例:
#   ./script/ops.sh deposit alice usdc 500
#   ./script/ops.sh borrow  alice weth 0.12 usdc 200
#   ./script/ops.sh repay   alice weth usdc max
#   ./script/ops.sh close   alice weth usdc
#   ./script/ops.sh reset-all

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../deploy-keys/.env.deploy"

POOL=0x6fc50Bbd108F39Fc6B0069c29f42e4A120C9df97
USDC_ADDR=0xe94C3c122204a1011EED9Ba9C11Aa8DEA861e91f
EURC_ADDR=0x657ff6937aC8913AD3DbEC44430BcdeD3af1367C
WETH_ADDR=0x78F1D761BC1E5D01b136e78A63AE444189ee02FB
RPC=https://rpc.testnet.arc.network
MAXU128=340282366920938463463374607431768211455

DEPLOYER_ADDR=$(cast wallet address "$PRIVATE_KEY")
ALICE_ADDR=$(cast wallet address "$PK_ALICE")
BOB_ADDR=$(cast wallet address "$PK_BOB")
CHARLIE_ADDR=$(cast wallet address "$PK_CHARLIE")

# ── 解析 account/asset 名称 ───────────────────────────────────────────────────

pk_of() {
  case "$1" in
    deployer) echo "$PRIVATE_KEY" ;;
    alice)    echo "$PK_ALICE" ;;
    bob)      echo "$PK_BOB" ;;
    charlie)  echo "$PK_CHARLIE" ;;
    *) echo "ERROR: 未知账户 '$1'，可选: deployer alice bob charlie" >&2; exit 1 ;;
  esac
}

addr_of() {
  case "$1" in
    deployer) echo "$DEPLOYER_ADDR" ;;
    alice)    echo "$ALICE_ADDR" ;;
    bob)      echo "$BOB_ADDR" ;;
    charlie)  echo "$CHARLIE_ADDR" ;;
    *) echo "ERROR: 未知账户 '$1'" >&2; exit 1 ;;
  esac
}

token_addr() {
  case "${1,,}" in
    usdc) echo "$USDC_ADDR" ;;
    eurc) echo "$EURC_ADDR" ;;
    weth) echo "$WETH_ADDR" ;;
    *) echo "ERROR: 未知资产 '$1'，可选: usdc eurc weth" >&2; exit 1 ;;
  esac
}

token_dec() {
  case "${1,,}" in
    weth) echo 18 ;;
    *)    echo 6 ;;
  esac
}

# 将人类可读数字转为链上整数 (python 处理小数)
to_units() {
  local amount=$1 decimals=$2
  python3 -c "
import decimal
decimal.getcontext().prec = 40
amt = decimal.Decimal('$amount')
dec = int('$decimals')
print(int(amt * 10**dec))
"
}

# ── 子命令 ───────────────────────────────────────────────────────────────────

cmd_mint() {
  local account=$1 asset=$2 amount=$3
  local token=$(token_addr "$asset")
  local dec=$(token_dec "$asset")
  local units=$(to_units "$amount" "$dec")
  local to=$(addr_of "$account")
  echo "mint $amount $asset → $account"
  cast send "$token" "mint(address,uint256)" "$to" "$units" \
    --private-key "$PRIVATE_KEY" --rpc-url "$RPC" --quiet
  echo "✓ done"
}

cmd_deposit() {
  local account=$1 asset=$2 amount=$3
  local pk=$(pk_of "$account")
  local token=$(token_addr "$asset")
  local dec=$(token_dec "$asset")
  local units=$(to_units "$amount" "$dec")
  echo "deposit $amount $asset (account=$account)"
  cast send "$token" "approve(address,uint256)" "$POOL" "$MAXU128" \
    --private-key "$pk" --rpc-url "$RPC" --quiet
  cast send "$POOL" "deposit(address,uint256)" "$token" "$units" \
    --private-key "$pk" --rpc-url "$RPC" --quiet
  echo "✓ done"
}

cmd_withdraw() {
  local account=$1 asset=$2 amount=$3
  local pk=$(pk_of "$account")
  local accaddr=$(addr_of "$account")
  local token=$(token_addr "$asset")
  local dec=$(token_dec "$asset")

  if [ "$amount" = "max" ]; then
    # 查 scaledDeposit → 计算 liveValue
    local raw
    raw=$(cast call "$POOL" "getLenderPosition(address,address)" "$token" "$accaddr" --rpc-url "$RPC")
    local units
    units=$(python3 -c "d='$raw'.replace('0x',''); print(int(d[0:64],16))")
    if [ "$units" -eq 0 ]; then
      echo "$account 在 $asset 中无存款，跳过"
      return
    fi
    echo "withdraw max $asset (account=$account, value=$units units)"
  else
    local units
    units=$(to_units "$amount" "$dec")
    echo "withdraw $amount $asset (account=$account)"
  fi

  cast send "$POOL" "withdraw(address,uint256)" "$token" "$units" \
    --private-key "$pk" --rpc-url "$RPC" --quiet
  echo "✓ done"
}

cmd_borrow() {
  local account=$1 col=$2 colAmt=$3 debt=$4 debtAmt=$5
  local pk=$(pk_of "$account")
  local colToken=$(token_addr "$col")
  local debtToken=$(token_addr "$debt")
  local colDec=$(token_dec "$col")
  local debtDec=$(token_dec "$debt")
  local colUnits=$(to_units "$colAmt" "$colDec")
  local debtUnits=$(to_units "$debtAmt" "$debtDec")
  echo "openPosition: $account puts $colAmt $col → borrows $debtAmt $debt"
  cast send "$colToken" "approve(address,uint256)" "$POOL" "$MAXU128" \
    --private-key "$pk" --rpc-url "$RPC" --quiet
  cast send "$POOL" "openPosition(address,uint256,address,uint256)" \
    "$colToken" "$colUnits" "$debtToken" "$debtUnits" \
    --private-key "$pk" --rpc-url "$RPC" --quiet
  echo "✓ done"
}

cmd_repay() {
  local account=$1 col=$2 debt=$3 amount=$4
  local pk=$(pk_of "$account")
  local accaddr=$(addr_of "$account")
  local colToken=$(token_addr "$col")
  local debtToken=$(token_addr "$debt")
  local debtDec=$(token_dec "$debt")

  if [ "$amount" = "max" ]; then
    local units=$MAXU128
    echo "repay MAX $debt (account=$account, pos=$col/$debt)"
  else
    local units=$(to_units "$amount" "$debtDec")
    echo "repay $amount $debt (account=$account, pos=$col/$debt)"
  fi

  cast send "$debtToken" "approve(address,uint256)" "$POOL" "$MAXU128" \
    --private-key "$pk" --rpc-url "$RPC" --quiet
  cast send "$POOL" "repay(address,address,address,uint128)" \
    "$accaddr" "$colToken" "$debtToken" "$units" \
    --private-key "$pk" --rpc-url "$RPC" --quiet
  echo "✓ done"
}

cmd_add_col() {
  local account=$1 col=$2 debt=$3 amount=$4
  local pk=$(pk_of "$account")
  local colToken=$(token_addr "$col")
  local debtToken=$(token_addr "$debt")
  local colDec=$(token_dec "$col")
  local units=$(to_units "$amount" "$colDec")
  echo "addCollateral $amount $col (account=$account, pos=$col/$debt)"
  cast send "$colToken" "approve(address,uint256)" "$POOL" "$MAXU128" \
    --private-key "$pk" --rpc-url "$RPC" --quiet
  cast send "$POOL" "addCollateral(address,address,uint256)" \
    "$colToken" "$debtToken" "$units" \
    --private-key "$pk" --rpc-url "$RPC" --quiet
  echo "✓ done"
}

cmd_with_col() {
  local account=$1 col=$2 debt=$3 amount=$4
  local pk=$(pk_of "$account")
  local accaddr=$(addr_of "$account")
  local colToken=$(token_addr "$col")
  local debtToken=$(token_addr "$debt")
  local colDec=$(token_dec "$col")

  if [ "$amount" = "max" ]; then
    local posraw
    posraw=$(cast call "$POOL" "getPosition(bytes32)" \
      "$(cast call "$POOL" "positionKey(address,address,address)" "$accaddr" "$colToken" "$debtToken" --rpc-url "$RPC")" \
      --rpc-url "$RPC")
    local units
    units=$(python3 -c "d='$posraw'.replace('0x',''); print(int(d[128:192],16))")
    if [ "$units" -eq 0 ]; then
      echo "$account 在 $col/$debt 中无抵押物，跳过"
      return
    fi
    echo "withdrawCollateral MAX $col (account=$account, pos=$col/$debt, colAmt=$units)"
  else
    local units=$(to_units "$amount" "$colDec")
    echo "withdrawCollateral $amount $col (account=$account, pos=$col/$debt)"
  fi

  cast send "$POOL" "withdrawCollateral(address,address,uint256)" \
    "$colToken" "$debtToken" "$units" \
    --private-key "$pk" --rpc-url "$RPC" --quiet
  echo "✓ done"
}

cmd_close() {
  local account=$1 col=$2 debt=$3
  echo "=== close: $account $col/$debt ==="
  cmd_repay "$account" "$col" "$debt" "max"
  cmd_with_col "$account" "$col" "$debt" "max"
}

cmd_reset_all() {
  echo "=== reset-all: 关闭所有仓位 + 提走所有存款 ==="
  echo "--- 还款并提取抵押物 ---"
  cmd_close alice    weth usdc
  cmd_close bob      usdc eurc
  cmd_close charlie  eurc usdc
  cmd_close deployer weth usdc

  echo "--- 提取所有存款 ---"
  cmd_withdraw alice    usdc max
  cmd_withdraw deployer usdc max
  cmd_withdraw charlie  eurc max
  cmd_withdraw bob      weth max
  # 清理微量余额
  cmd_withdraw charlie  usdc max
  cmd_withdraw bob      eurc max
  echo "=== reset-all 完成 ==="
}

# ── 入口 ─────────────────────────────────────────────────────────────────────

CMD="${1:-help}"
shift || true

case "$CMD" in
  mint)     cmd_mint     "$@" ;;
  deposit)  cmd_deposit  "$@" ;;
  withdraw) cmd_withdraw "$@" ;;
  borrow)   cmd_borrow   "$@" ;;
  repay)    cmd_repay    "$@" ;;
  add-col)  cmd_add_col  "$@" ;;
  with-col) cmd_with_col "$@" ;;
  close)    cmd_close    "$@" ;;
  reset-all) cmd_reset_all ;;
  help|*)
    sed -n '/^# 用法/,/^$/p' "$0"
    ;;
esac
