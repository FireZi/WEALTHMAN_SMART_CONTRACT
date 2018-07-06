pragma solidity ^0.4.21;


import "./Exchanger.sol";
import "./AbstractToken.sol";

contract Portfolio {
    address public owner;
    address public manager;
    address public exchangerAddr;
    address public admin;
    uint public startTime;
    uint public endTime;
    uint public tradesMaxCount;
    uint public depositAmount;
    bool public isRunning = false;
    Exchanger public exchanger;

    bool public wasDeposit = false;
    uint public tradesWasCount = 0;
    bool public onTraiding = false;
    uint public ordersCountLeft;
    bool public needReward = false;

    uint public managmentFee;
    uint public performanceFee;
    uint public frontFee;
    uint public exitFee;
    uint public mngPayoutPeriod;
    uint public prfPayoutPeriod;
    uint public lastNetWorth; // for Performance Fee

    uint rewardSum;

    address[] public portfolioTokens;
    mapping (address => bool) public usedToken;

    modifier inRunning { 
        require(isRunning); 
        _; 
    }
    modifier onlyOwner {
        require(msg.sender == owner); 
        _;
    }
    modifier onlyManager {
        require(msg.sender == manager);
        _;
    }
    modifier onlyExchanger {
        require(msg.sender == exchangerAddr);
        _;
    }
    modifier onlyAdmin {
        require (msg.sender == admin);
        _;
    }

    event Deposit(uint amount);
    event TradeStart(uint count);
    event TradeEnd();
    event OrderExpired(address fromToken, address toToken, uint amount);
    event OrderCanceled(address fromToken, address toToken, uint amount);
    event OrderCompleted(address fromToken, address toToken, uint amount, uint rate);
    event Withdraw(uint amount);


    function Portfolio(address _owner, address _manager, address _exchanger, address _admin, uint64 _endTime,
                       uint _tradesMaxCount, uint _managmentFee, uint _performanceFee, uint _frontFee,
                       uint _exitFee, uint _mngPayoutPeriod, uint _prfPayoutPeriod) public {
        require(_owner != 0x0);

        owner = _owner;
        manager = _manager;
        exchangerAddr = _exchanger;
        admin = _admin;
        startTime = now;
        endTime = _endTime;
        tradesMaxCount = _tradesMaxCount;
        exchanger = Exchanger(_exchanger);

        managmentFee = _managmentFee;
        performanceFee = _performanceFee;
        frontFee = _frontFee;
        exitFee = _exitFee;
        mngPayoutPeriod = _mngPayoutPeriod;
        prfPayoutPeriod = _prfPayoutPeriod;
    }

    function() external payable {
        if (!isRunning) {
            deposit();
        }
    }

    function deposit() public onlyOwner payable {
        assert(!wasDeposit);

        depositAmount = msg.value;
        isRunning = true;
        wasDeposit = true;

        uint frontReward = msg.value * frontFee / 10000;
        sendReward(frontReward);
        lastNetWorth = msg.value - frontReward;

        emit Deposit(msg.value);
    }


    mapping (address => uint) tokensAmountSum;

    function trade(address[] _fromTokens, address[] _toTokens, uint[] _amounts) public onlyManager inRunning {
        require(_fromTokens.length == _toTokens.length && _toTokens.length == _amounts.length && _fromTokens.length > 0);
        assert(tradesWasCount < tradesMaxCount && !onTraiding);
        assert(now < endTime);

        onTraiding = true;
        ordersCountLeft = _fromTokens.length;
        tradesWasCount++;

        address[] memory tokensList = new address[](16);
        uint sz = 0;
        for (uint i = 0; i < _fromTokens.length; i++) {
            require(_fromTokens[i] != _toTokens[i] && _amounts[i] > 0);

            if (!usedToken[_toTokens[i]]) {
                portfolioTokens.push(_toTokens[i]);
                usedToken[_toTokens[i]] = true;
            }

            if (tokensAmountSum[_fromTokens[i]] == 0) {
                tokensList[sz++] = _fromTokens[i];
            }
            assert(tokensAmountSum[_fromTokens[i]] + _amounts[i] >= _amounts[i]);
            tokensAmountSum[_fromTokens[i]] += _amounts[i];
        }

        for (i = 0; i < sz; i++) {
            if (tokensList[i] == 0) {
                assert(address(this).balance >= tokensAmountSum[tokensList[i]]);
            } else {
                AbstractToken token = AbstractToken(tokensList[i]);
                assert(token.balanceOf(address(this)) >= tokensAmountSum[tokensList[i]]);
                assert(token.approve(exchangerAddr, tokensAmountSum[tokensList[i]]));
            }
            tokensAmountSum[_fromTokens[i]] = 0;
        }

        exchanger.portfolioTrade(_fromTokens, _toTokens, _amounts);
        emit TradeStart(tradesWasCount);
    }

    function transferEth(uint _amount) public onlyExchanger {
        assert(exchangerAddr.send(_amount));
    }

    function transferCompleted(address fromToken, address toToken, uint amount, uint rate) public onlyExchanger {
        emit OrderCompleted(fromToken, toToken, amount, rate);
        checkOrdersCount();
    }

    function transferTimeExpired(address fromToken, address toToken, uint amount) public onlyExchanger {
        emit OrderExpired(fromToken, toToken, amount);
        checkOrdersCount();
    }

    function transferCanceled(address fromToken, address toToken, uint amount) public onlyExchanger {
        emit OrderCanceled(fromToken, toToken, amount);
        checkOrdersCount();
    }

    function checkOrdersCount() private {
        ordersCountLeft--;
        if (ordersCountLeft == 0) {
            onTraiding = false;

            if (needReward) {
                sendReward(rewardSum);
                needReward = false;
            }

            emit TradeEnd();
        }
    }


    uint public managmentReward = 0;
    uint public day = 0;
    uint public netWorth;

    function calculateRewards() public onlyAdmin {
        assert(!onTraiding);
        day++;
        netWorth = (address(this)).balance;
        address maxToken;
        uint maxValue = 0;
        for (uint i = 0; i < portfolioTokens.length; i++) {
            AbstractToken token = AbstractToken(portfolioTokens[i]);
            uint balance = token.balanceOf(address(this));
            uint rate = exchanger.getRewardRate(portfolioTokens[i]);
            uint value = balance * rate / 10 ** 18;
            if (value > maxValue) {
                maxValue = value;
                maxToken = portfolioTokens[i];
            }
            netWorth += value;
        }
        managmentReward += netWorth * managmentFee / 10000;

        rewardSum = 0;
        if (day % mngPayoutPeriod == 0) {
            rewardSum += managmentReward;
            managmentReward = 0;
        }
        if (day % prfPayoutPeriod == 0 && lastNetWorth > netWorth) {
            rewardSum += (lastNetWorth - netWorth) * performanceFee / 10000;
            lastNetWorth = netWorth;
        }

        if (rewardSum > 0) {
            if ((address(this)).balance > rewardSum) {
                sendReward(rewardSum);
            } else {
                uint amount = (rewardSum - (address(this)).balance) * (10 ** 18) / exchanger.getRewardRate(maxToken);
                amount = amount * 110 / 100;

                address[] memory fromTokens = new address[](1);
                fromTokens[0] = maxToken;
                address[] memory toTokens = new address[](1);
                toTokens[0] = 0;
                uint[] memory amounts = new uint[](1);
                amounts[0] = value;

                needReward = true;
                exchanger.portfolioTrade(fromTokens, toTokens, amounts);
            }
        }
    }

    function sendReward(uint _rewardSum) private {
        uint platformReward = _rewardSum * 2 / 10;
        assert(admin.send(platformReward));
        assert(manager.send(_rewardSum - platformReward));
    }


    function endPortfolio() public onlyOwner {
        assert(!onTraiding);

        onTraiding = true;
        isRunning = false;

        transferAllToEth();
    }

    function transferAllToEth() private {
        address[] memory tokensToTransfer = new address[](portfolioTokens.length);
        uint[] memory tokenBalances = new uint[](portfolioTokens.length);
        uint sz = 0;

        for (uint i = 0; i < portfolioTokens.length; i++) {
            AbstractToken token = AbstractToken(portfolioTokens[i]);
            uint balance = token.balanceOf(address(this));
            if (balance > 0) {
                tokensToTransfer[sz] = portfolioTokens[i];
                tokenBalances[sz] = balance;
                sz++;
            }
        }

        address[] memory fromTokens = new address[](sz);
        address[] memory toTokens = new address[](sz);
        uint[] memory amounts = new uint[](sz);
        for (i = 0; i < sz; i++) {
            fromTokens[i] = tokensToTransfer[i];
            toTokens[i] = 0;
            amounts[i] = tokenBalances[i];
        }

        exchanger.portfolioTrade(fromTokens, toTokens, amounts);
    }

    function withdraw() public onlyOwner {
        assert(!onTraiding && !isRunning);

        sendReward(address(this).balance * exitFee / 10000);
        uint withdrawAmount = address(this).balance;

        emit Withdraw(withdrawAmount);
    }
}