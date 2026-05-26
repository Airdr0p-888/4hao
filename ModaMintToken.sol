// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

library SafeMath {
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) { unchecked { uint256 c = a + b; if (c < a) return (false, 0); return (true, c); } }
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) { unchecked { if (b > a) return (false, 0); return (true, a - b); } }
    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) { unchecked { if (a == 0) return (true, 0); uint256 c = a * b; if (c / a != b) return (false, 0); return (true, c); } }
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) { unchecked { if (b == 0) return (false, 0); return (true, a / b); } }
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) { unchecked { if (b == 0) return (false, 0); return (true, a % b); } }
    function add(uint256 a, uint256 b) internal pure returns (uint256) { return a + b; }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) { return a - b; }
    function mul(uint256 a, uint256 b) internal pure returns (uint256) { return a * b; }
    function div(uint256 a, uint256 b) internal pure returns (uint256) { return a / b; }
    function mod(uint256 a, uint256 b) internal pure returns (uint256) { return a % b; }
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) { unchecked { require(b <= a, errorMessage); return a - b; } }
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) { unchecked { require(b > 0, errorMessage); return a / b; } }
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) { unchecked { require(b > 0, errorMessage); return a % b; } }
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function swapExactTokensForETH(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external returns (uint[] memory amounts);
    function addLiquidityETH(
        address token, uint amountTokenDesired, uint amountTokenMin, uint amountETHMin,
        address to, uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint) external;
}

/// @title Ownable —— 手动实现，去除 OpenZeppelin 的 Context 依赖
abstract contract Ownable {
    address internal _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() { _owner = msg.sender; emit OwnershipTransferred(address(0), msg.sender); }
    function owner() public view virtual returns (address) { return _owner; }
    modifier onlyOwner() { require(owner() == msg.sender, "Ownable: caller is not owner"); _; }
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }
}

contract ModaMintToken is IERC20, Ownable {
    using SafeMath for uint256;

    string private _name;
    string private _symbol;
    uint8  private constant _decimals = 18;
    uint256 private _totalSupply;
    uint256 private constant MAX_TAX = 2500;   // 最高 25%
    uint256 private constant DIVIDEND_PRECISION = 1e18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // ===== 分红系统（BNB 直发模式）=====
    uint256 public dividendsPerShare;
    uint256 public totalDividendDistributed;
    uint256 public _availableDivFunds;
    mapping(address => int256) public magnifiedDividendCorrections;
    uint256 public minHoldForDividend;
    uint256 public dividendCooldown = 100;
    uint256 public lastDividendBlock;
    uint256 public dividendBps;

    // ===== 税费系统 =====
    uint256 public buyTaxBps;
    uint256 public sellTaxBps;
    uint256 public marketingBps;
    uint256 public burnBps;
    uint256 public liquidityBps;
    uint256 public pendingMarketingTokens;
    address public marketingWallet;
    address public dividendToken;    // 已弃用，分红现用原生 BNB

    // ===== DEX =====
    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;
    bool public tradingActive;

    // ===== 反机器人（已移除）=====
    mapping(address => bool) public isExcludedFromTax;

    // ===== Mint 预售 =====
    uint256 public mintCostBNB;
    uint256 public tokensPerMint;
    uint256 public fillAmountBNB;
    uint256 public totalBNBCollected;
    mapping(address => uint256) public mintedAmount;
    bool public presaleActive;
    bool public whitelistMintOnly;
    mapping(address => bool) public whitelist;

    // ===== 分红 swap 状态 =====
    uint256 public dividendSwapThreshold = 10 * 1e18;
    uint256 public pendingSwapForDividend;
    uint256 public pendingLiquidityTokens;
    bool private inSwap;
    modifier lockTheSwap() { inSwap = true; _; inSwap = false; }

    // ===== 事件 =====
    event TradingEnabled();
    event PresaleEnded();
    event DividendProcessed(uint256 tokensSwapped, uint256 dividendReceived);
    event DividendSwapFailed(uint256 amountAttempted);
    event DividendClaimed(address indexed holder, address indexed dividendToken, uint256 amount);
    event Mint(address indexed user, uint256 bnbCost, uint256 tokenAmount);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        uint256 mintCostBNB_,
        uint256 fillBNB_,
        uint256 buyTax_,
        uint256 sellTax_,
        uint256 marketingPct_,
        uint256 burnPct_,
        uint256 dividendPct_,
        uint256 liquidityPct_,
        address marketingWallet_,
        address dividendToken_,
        uint256 minHoldForDividend_,
        uint256 presaleTokenPct_,
        bool    whitelistMintOnly_,
        address owner_
    ) {
        require(buyTax_ <= MAX_TAX, "Buy tax too high");
        require(sellTax_ <= MAX_TAX, "Sell tax too high");
        require(marketingPct_ + burnPct_ + dividendPct_ + liquidityPct_ == 10000, "Tax alloc != 10000");
        require(fillBNB_ > 0, "Fill must > 0");
        require(mintCostBNB_ > 0, "Mint cost > 0");
        require(fillBNB_ >= mintCostBNB_, "Fill < mint cost");
        require(marketingWallet_ != address(0), "Wallet zero");
        require(owner_ != address(0), "Owner zero");
        require(presaleTokenPct_ >= 1 && presaleTokenPct_ <= 99, "Presale pct 1-99");

        _name = name_;
        _symbol = symbol_;
        _totalSupply = totalSupply_ * 1e18;
        _balances[address(this)] = _totalSupply;

        emit OwnershipTransferred(address(0), msg.sender);
        emit OwnershipTransferred(msg.sender, owner_);
        _owner = owner_;

        dividendSwapThreshold = 10 * 1e18;
        dividendBps = dividendPct_;
        lastDividendBlock = block.number;
        minHoldForDividend = minHoldForDividend_;
        dividendToken = dividendToken_;  // 保留兼容

        IUniswapV2Router02 _router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        uniswapV2Router = _router;
        uniswapV2Pair = IUniswapV2Factory(_router.factory()).createPair(address(this), _router.WETH());

        isExcludedFromTax[address(this)] = true;
        isExcludedFromTax[owner_] = true;
        isExcludedFromTax[marketingWallet_] = true;
        isExcludedFromTax[address(_router)] = true;

        buyTaxBps = buyTax_;
        sellTaxBps = sellTax_;
        marketingBps = marketingPct_;
        burnBps = burnPct_;
        dividendBps = dividendPct_;
        liquidityBps = liquidityPct_;
        marketingWallet = marketingWallet_;
        whitelistMintOnly = whitelistMintOnly_;
        presaleActive = true;
        tradingActive = false;

        mintCostBNB = mintCostBNB_;
        fillAmountBNB = fillBNB_;
        tokensPerMint = _totalSupply.mul(presaleTokenPct_).div(100).div(fillBNB_.div(mintCostBNB_));
    }

    // ===== ERC20 =====
    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public pure returns (uint8) { return _decimals; }
    function totalSupply() public view override returns (uint256) { return _totalSupply; }
    function balanceOf(address a) public view override returns (uint256) { return _balances[a]; }
    function allowance(address a, address spender) public view override returns (uint256) { return _allowances[a][spender]; }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _tryAutoSwap();
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20: exceed allowance");
        unchecked { _approve(from, msg.sender, currentAllowance - amount); }
        _transfer(from, to, amount);
        return true;
    }

    function _approve(address _owner, address spender, uint256 amount) internal {
        require(_owner != address(0) && spender != address(0));
        _allowances[_owner][spender] = amount;
        emit Approval(_owner, spender, amount);
    }

    receive() external payable {
        if (presaleActive) {
            mint(); // 预售中：直接转账 = 自动 Mint
        }
        // 预售结束后：静默接收 BNB（分红 swap 等用途）
    }

    // ===== 核心 _transfer =====
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "Zero address");
        require(amount > 0, "Amount zero");
        require(_balances[from] >= amount, "Insufficient balance");

        // 在 DEX 交易开始时触发分红 swap（仅卖出/转帐时，买入时 Pair 锁定不可重入）
        if (from != uniswapV2Pair) {
            _tryAutoSwap();
        }

        bool isDexTransfer = (from == uniswapV2Pair || to == uniswapV2Pair);
        if (isDexTransfer && !tradingActive) {
            require(isExcludedFromTax[from] || isExcludedFromTax[to], "Trading not active");
        }

        // ✅ 先算税，避免 correction 用错余额
        bool isBuy  = (from == uniswapV2Pair && to != address(uniswapV2Router));
        bool isSell = (to == uniswapV2Pair && from != address(uniswapV2Router));
        uint256 taxAmount = 0;

        if (!isExcludedFromTax[from] && !isExcludedFromTax[to]) {
            if (isBuy)  taxAmount = amount.mul(buyTaxBps).div(10000);
            if (isSell) taxAmount = amount.mul(sellTaxBps).div(10000);
        }

        uint256 sendAmt = amount.sub(taxAmount);

        // ✅ 自动派发分红（push 模式）
        if (dividendBps > 0) {
            _autoClaimDividend(from);
            _autoClaimDividend(to);
        }

        // 分红修正值更新（用 sendAmt 而不是 amount，因为 to 只收到 sendAmt）
        if (dividendBps > 0 && dividendsPerShare > 0) {
            magnifiedDividendCorrections[from] += int256(amount) * int256(dividendsPerShare);
            magnifiedDividendCorrections[to]   -= int256(sendAmt) * int256(dividendsPerShare);
        }

        _balances[from] = _balances[from].sub(amount);
        _balances[to] = _balances[to].add(sendAmt);

        if (taxAmount > 0) {
            _balances[address(this)] = _balances[address(this)].add(taxAmount);
            _distributeTax(taxAmount);
        }

        emit Transfer(from, to, sendAmt);
    }

    function _distributeTax(uint256 taxAmt) internal {
        // 营销税也进 swap 池，swap 后发 BNB 给营销钱包（不再直接发代币）
        uint256 mkt = taxAmt.mul(marketingBps).div(10000);
        if (mkt > 0 && marketingWallet != address(0)) {
            pendingMarketingTokens = pendingMarketingTokens.add(mkt);
        }
        uint256 burn = taxAmt.mul(burnBps).div(10000);
        if (burn > 0) {
            _balances[address(this)] = _balances[address(this)].sub(burn);
            _totalSupply = _totalSupply.sub(burn);
            emit Transfer(address(this), address(0), burn);
        }
        uint256 liq = taxAmt.mul(liquidityBps).div(10000);
        if (liq > 0) {
            pendingLiquidityTokens = pendingLiquidityTokens.add(liq);
        }
        if (dividendBps > 0) {
            uint256 divAmt = taxAmt.mul(dividendBps).div(10000);
            if (divAmt > 0) {
                pendingSwapForDividend = pendingSwapForDividend.add(divAmt);
            }
        }
    }

    // ===== 分红系统 =====
    function _autoClaimDividend(address account) internal {
        if (dividendBps == 0 || dividendsPerShare == 0) return;
        if (account == uniswapV2Pair || account == address(this) || account == address(0)) return;
        if (_balances[account] < minHoldForDividend) return;

        int256 mag = int256(_balances[account]) * int256(dividendsPerShare)
                     + magnifiedDividendCorrections[account];
        if (mag <= 0) return;

        uint256 pending = uint256(mag) / DIVIDEND_PRECISION;
        if (pending == 0) return;
        if (pending > _availableDivFunds) return;

        _availableDivFunds = _availableDivFunds.sub(pending);
        magnifiedDividendCorrections[account] = -int256(_balances[account]) * int256(dividendsPerShare);

        (bool success, ) = account.call{value: pending}("");
        if (!success) {
            // 如果转账失败（如合约钱包拒绝接收 BNB），恢复状态
            _availableDivFunds = _availableDivFunds.add(pending);
            magnifiedDividendCorrections[account] = magnifiedDividendCorrections[account]
                + int256(pending * DIVIDEND_PRECISION);
        }
        emit DividendClaimed(account, address(0), pending);
    }

    function getPendingDividend(address account) public view returns (uint256) {
        if (_balances[account] == 0 || dividendBps == 0) return 0;
        if (_balances[account] < minHoldForDividend) return 0;
        int256 mag = int256(_balances[account]) * int256(dividendsPerShare)
                     + magnifiedDividendCorrections[account];
        if (mag <= 0) return 0;
        return uint256(mag) / DIVIDEND_PRECISION;
    }

    function claimDividend() external {
        _tryAutoSwap();
        uint256 pending = getPendingDividend(msg.sender);
        require(pending > 0, "Nothing to claim");
        require(_balances[msg.sender] >= minHoldForDividend, "Below min hold");
        require(pending <= _availableDivFunds, "Insufficient dividend funds");

        _availableDivFunds = _availableDivFunds.sub(pending);
        magnifiedDividendCorrections[msg.sender] = magnifiedDividendCorrections[msg.sender]
            - int256(pending * DIVIDEND_PRECISION);

        (bool success, ) = msg.sender.call{value: pending}("");
        require(success, "BNB transfer failed");
        emit DividendClaimed(msg.sender, address(0), pending);
    }

    /// @notice 手动触发分红 swap
    function triggerDividendSwap() external {
        uint256 totalPending = pendingSwapForDividend + pendingLiquidityTokens + pendingMarketingTokens;
        require(totalPending >= dividendSwapThreshold, "Below threshold");
        require(!inSwap, "Swap in progress");
        _processDividendSwap();
    }

    /// @dev 非 DEX 上下文 or 手动触发时调用
    function _tryAutoSwap() internal {
        if (inSwap || dividendSwapThreshold == 0) return;
        uint256 total = pendingSwapForDividend + pendingLiquidityTokens + pendingMarketingTokens;
        if (total >= dividendSwapThreshold) {
            _processDividendSwap();
        }
    }

    /// @dev 内部：swap 代币 → BNB（PancakeSwap Router 无 lock，可直接调用）
    function _processDividendSwap() internal lockTheSwap {
        uint256 divAmt = pendingSwapForDividend;
        uint256 liqAmt = pendingLiquidityTokens;
        uint256 mktAmt = pendingMarketingTokens;
        uint256 totalAmt = divAmt + liqAmt + mktAmt;
        if (totalAmt == 0) return;

        pendingSwapForDividend = 0;
        pendingLiquidityTokens = 0;
        pendingMarketingTokens = 0;

        address weth = uniswapV2Router.WETH();
        _approve(address(this), address(uniswapV2Router), totalAmt);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = weth;

        uint256 bnbBefore = address(this).balance;

        try uniswapV2Router.swapExactTokensForETH(
            totalAmt, 0, path, address(this), block.timestamp
        ) {
            // swap 成功
        } catch {
            pendingSwapForDividend = pendingSwapForDividend.add(divAmt);
            pendingLiquidityTokens = pendingLiquidityTokens.add(liqAmt);
            pendingMarketingTokens = pendingMarketingTokens.add(mktAmt);
            emit DividendSwapFailed(totalAmt);
            return;
        }

        uint256 bnbReceived = address(this).balance - bnbBefore;

        // 按代币比例分配 BNB（营销 → 直发，分红 → dps 池，流动性 → 留存）
        uint256 mktBNB = (mktAmt > 0 && marketingWallet != address(0)) ? bnbReceived.mul(mktAmt).div(totalAmt) : 0;
        uint256 divBNB = (divAmt > 0) ? bnbReceived.mul(divAmt).div(totalAmt) : 0;

        // 营销 BNB → 直发营销钱包
        if (mktBNB > 0) {
            (bool ok, ) = marketingWallet.call{value: mktBNB}("");
            if (!ok) {
                pendingMarketingTokens = pendingMarketingTokens.add(mktAmt);
            } else {
                emit DividendClaimed(marketingWallet, address(0), mktBNB);
            }
        }

        // 分红 BNB → 更新 dps
        if (divBNB > 0) {
            uint256 ts = _totalSupply;
            if (ts > 0) {
                dividendsPerShare = dividendsPerShare.add(
                    divBNB.mul(DIVIDEND_PRECISION).div(ts)
                );
                totalDividendDistributed = totalDividendDistributed.add(divBNB);
                _availableDivFunds = _availableDivFunds.add(divBNB);
            }
            emit DividendProcessed(totalAmt, divBNB);
        }
        // 流动性 BNB 部分留在合约中
    }

    // ===== 管理员函数 =====
    function setBuyTax(uint256 bps) external onlyOwner { require(bps <= MAX_TAX); buyTaxBps = bps; }
    function setSellTax(uint256 bps) external onlyOwner { require(bps <= MAX_TAX); sellTaxBps = bps; }
    function setMarketingWallet(address w) external onlyOwner { require(w != address(0)); marketingWallet = w; }
    function excludeFromTax(address a, bool ex) external onlyOwner { isExcludedFromTax[a] = ex; }
    function withdrawBNB() external onlyOwner { payable(owner()).transfer(address(this).balance); }

    function emergencyWithdrawToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }

    function setMarketingBps(uint256 bps) external onlyOwner {
        require(bps + burnBps + dividendBps + liquidityBps <= 10000, "Total > 100%");
        marketingBps = bps;
    }
    function setBurnBps(uint256 bps) external onlyOwner {
        require(marketingBps + bps + dividendBps + liquidityBps <= 10000, "Total > 100%");
        burnBps = bps;
    }
    function setDividendBps(uint256 bps) external onlyOwner {
        require(marketingBps + burnBps + bps + liquidityBps <= 10000, "Total > 100%");
        dividendBps = bps;
    }
    function setLiquidityBps(uint256 bps) external onlyOwner {
        require(marketingBps + burnBps + dividendBps + bps <= 10000, "Total > 100%");
        liquidityBps = bps;
    }

    function setMinHoldForDividend(uint256 amt) external onlyOwner { minHoldForDividend = amt; }
    function setDividendSwapThreshold(uint256 amt) external onlyOwner { dividendSwapThreshold = amt; }
    function setDividendCooldown(uint256 blocks) external onlyOwner { dividendCooldown = blocks; }

    function enableTrading() external onlyOwner {
        require(!tradingActive, "Already active");
        tradingActive = true;
        emit TradingEnabled();
    }

    // ===== Mint 预售 =====
    function setMintPrice(uint256 costBNB_, uint256 fillBNB_) external onlyOwner {
        require(costBNB_ > 0 && fillBNB_ >= costBNB_, "Invalid params");
        mintCostBNB = costBNB_;
        fillAmountBNB = fillBNB_;
        tokensPerMint = _totalSupply.mul(50).div(100).div(fillBNB_.div(costBNB_));
    }

    function addWhitelist(address[] calldata users) external onlyOwner {
        for (uint i = 0; i < users.length; i++) whitelist[users[i]] = true;
    }
    function removeWhitelist(address[] calldata users) external onlyOwner {
        for (uint i = 0; i < users.length; i++) whitelist[users[i]] = false;
    }
    function setWhitelistMintOnly(bool v) external onlyOwner { whitelistMintOnly = v; }

    function mint() public payable {
        require(presaleActive, "Presale not active");
        require(msg.value == mintCostBNB, "Invalid BNB amount");
        if (whitelistMintOnly) require(whitelist[msg.sender], "Not whitelisted");
        require(totalBNBCollected.add(msg.value) <= fillAmountBNB, "Presale full");

        totalBNBCollected = totalBNBCollected.add(msg.value);
        uint256 tokenAmt = tokensPerMint;
        require(_balances[address(this)] >= tokenAmt, "Insufficient contract balance");

        _balances[msg.sender] = _balances[msg.sender].add(tokenAmt);
        _balances[address(this)] = _balances[address(this)].sub(tokenAmt);
        mintedAmount[msg.sender] = mintedAmount[msg.sender].add(tokenAmt);

        emit Mint(msg.sender, msg.value, tokenAmt);
        emit Transfer(address(this), msg.sender, tokenAmt);

        if (totalBNBCollected >= fillAmountBNB) {
            presaleActive = false;
            emit PresaleEnded();

            // 自动加底池：合约剩余代币 + 募集 BNB 配对加流动性
            _addInitialLiquidity();

            // 加完底池后才开启交易
            tradingActive = true;
            emit TradingEnabled();
        }
    }

    function withdrawPresaleBNB() external onlyOwner {
        uint256 bal = address(this).balance;
        require(bal > 0, "No BNB");
        payable(owner()).transfer(bal);
    }

    function addLiquidity() external onlyOwner {
        uint256 tokenAmt = pendingLiquidityTokens;
        uint256 bnbAmt = address(this).balance;
        require(tokenAmt > 0 && bnbAmt > 0, "Nothing to add");

        pendingLiquidityTokens = 0;
        _approve(address(this), address(uniswapV2Router), tokenAmt);

        uniswapV2Router.addLiquidityETH{value: bnbAmt}(
            address(this), tokenAmt, 0, 0, owner(), block.timestamp
        );
    }

    event InitialLiquidityAdded(uint256 tokens, uint256 bnb);

    /// @dev 预售满时自动加初始流动性（用合约剩余代币 + 募集 BNB）
    function _addInitialLiquidity() internal {
        uint256 tokenBal = _balances[address(this)];
        uint256 bnbBal = address(this).balance;
        if (tokenBal == 0 || bnbBal == 0) return;

        // 扣除 pending 中的累积（虽然预售期间理论上为 0，但安全起见）
        uint256 pendingDiv = pendingSwapForDividend;
        uint256 pendingLiq = pendingLiquidityTokens;
        uint256 lockedTokens = pendingDiv + pendingLiq;
        if (tokenBal <= lockedTokens) return;
        uint256 lpTokens = tokenBal - lockedTokens;

        pendingSwapForDividend = 0;
        pendingLiquidityTokens = 0;

        _approve(address(this), address(uniswapV2Router), lpTokens);
        (uint256 tokenUsed, uint256 bnbUsed, ) = uniswapV2Router.addLiquidityETH{value: bnbBal}(
            address(this), lpTokens, 0, 0, owner(), block.timestamp
        );

        emit InitialLiquidityAdded(tokenUsed, bnbUsed);
    }
}
