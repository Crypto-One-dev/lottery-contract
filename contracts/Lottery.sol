// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import '@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol';
import '@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol';
import '@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol';
import '@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol';

import "./LotteryNFT.sol";

contract Lottery is Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    uint8 constant keyLengthForEachBuy = 11;
    // Allocation for first/sencond/third reward
    uint256[] private allocation = [60, 20, 10];
    // The TOKEN to buy lottery
    IBEP20 public cake;
    // The Lottery NFT for tickets
    LotteryNFT public lotteryNFT;
    // adminAddress
    address public adminAddress;
    // maxNumber
    uint256 public maxNumber = 5;

    // =================================

    // issueId => winningNumbers[numbers]
    mapping (uint256 => uint8[4]) public historyNumbers;
    // issueId => [tokenId]
    mapping (uint256 => uint256[]) public lotteryInfo;
    // issueId => [totalAmount, firstMatchAmount, secondMatchingAmount, thirdMatchingAmount]
    mapping (uint256 => uint256[]) public historyAmount;
    // issueId => buyAmountSum
    mapping (uint256 => mapping(uint64 => uint256)) public userBuyAmountSum;
    // address => [tokenId]
    mapping (address => uint256[]) public userInfo;

    uint256 public issueIndex = 0;
    uint256 public totalAddresses = 0;
    uint256 public totalAmount = 0;
    uint256 public lastTimestamp;

    uint8[4] public winningNumbers;

    // =================================

    event Buy(address indexed user, uint256 tokenId);
    event Drawing(uint256 indexed issueIndex, uint8[4] winningNumbers);
    event Claim(address indexed user, uint256 tokenid, uint256 amount);
    event DevWithdraw(address indexed user, uint256 amount);
    event Reset(uint256 indexed issueIndex);
    event MultiClaim(address indexed user, uint256 amount);
    event MultiBuy(address indexed user, uint256 amount);

    constructor(
        IERC20 _cake,
        LotteryNFT _lottery,
        uint256 _maxNumber,
        address _adminAddress
    ) public {
        cake = _cake;
        lotteryNFT = _lottery;
        maxNumber = _maxNumber;
        adminAddress = _adminAddress;
        lastTimestamp = block.timestamp;
    }

    uint8[4] public nullTicket = [0,0,0,0];

    function drawed() public view returns(bool res) {
        return winningNumbers[0] != 0;
    }

    function reset() external {
        require(msg.sender == adminAddress, "admin: wut?");
        require(drawed(), "drawed?");
        lastTimestamp = block.timestamp;
        totalAddresses = 0;
        totalAmount = 0;
        winningNumbers[0]=0;
        winningNumbers[1]=0;
        winningNumbers[2]=0;
        winningNumbers[3]=0;
        issueIndex = issueIndex +1;
        if(getMatchingRewardAmount(issueIndex-1, 4) == 0) {
            uint256 amount = getTotalRewards(issueIndex-1).mul(allocation[0]).div(100);
            buy(amount, nullTicket);
        }
        emit Reset(issueIndex);
    }

    function drawing() public {
        require(msg.sender == adminAddress, "admin: wut?");
        require(!drawed(), "reset?");
        bytes32 _structHash;
        uint256 _randomNumber;
        uint256 _maxNumber = maxNumber;
        bytes32 _blockhash = blockhash(block.number-1);

        // 1
        _structHash = keccak256(
            abi.encode(
                _blockhash,
                totalAddresses
            )
        );
        _randomNumber  = uint256(_structHash);
        assembly {_randomNumber := add(mod(_randomNumber, _maxNumber),1)}
        winningNumbers[0]=uint8(_randomNumber);

        // 2
        _structHash = keccak256(
            abi.encode(
                _blockhash,
                totalAmount
            )
        );
        _randomNumber  = uint256(_structHash);
        assembly {_randomNumber := add(mod(_randomNumber, _maxNumber),1)}
        winningNumbers[1]=uint8(_randomNumber);

        // 3
        _structHash = keccak256(
            abi.encode(
                _blockhash,
                lastTimestamp
            )
        );
        _randomNumber  = uint256(_structHash);
        assembly {_randomNumber := add(mod(_randomNumber, _maxNumber),1)}
        winningNumbers[2]=uint8(_randomNumber);

        // 4
        _structHash = keccak256(
            abi.encode(
                _blockhash,
                block.difficulty
            )
        );
        _randomNumber  = uint256(_structHash);
        assembly {_randomNumber := add(mod(_randomNumber, _maxNumber),1)}
        winningNumbers[3]=uint8(_randomNumber);

        historyNumbers[issueIndex] = winningNumbers;
        historyAmount[issueIndex] = calculateMatchingRewardAmount();
        emit Drawing(issueIndex, winningNumbers);
    }

    function buy(uint256 _amount, uint8[4] memory _numbers) public {
        require (!drawed(), 'drawed, can not buy now');
        for (uint i = 0; i < 4; i++) {
            require (_numbers[i] <= maxNumber, 'exceed the maximum');
        }
        if(_numbers[0] == 0)  {
            uint256 tokenId = lotteryNFT.newLotteryItem(address(this), _numbers, _amount, issueIndex);
            lotteryInfo[issueIndex].push(tokenId);
            totalAmount = totalAmount + _amount;
            lastTimestamp = block.timestamp;
            emit Buy(address(this), tokenId);
        }
        else {
            uint256 tokenId = lotteryNFT.newLotteryItem(msg.sender, _numbers, _amount, issueIndex);
            lotteryInfo[issueIndex].push(tokenId);
            if (userInfo[msg.sender].length == 0) {
                totalAddresses = totalAddresses + 1;
            }
            userInfo[msg.sender].push(tokenId);
            totalAmount = totalAmount + _amount;
            lastTimestamp = block.timestamp;
            cake.safeTransferFrom(address(msg.sender), address(this), _amount);
            uint64[keyLengthForEachBuy] memory userNumberIndex = generateNumberIndexKey(_numbers);
            for (uint i = 0; i < keyLengthForEachBuy; i++) {
                userBuyAmountSum[issueIndex][userNumberIndex[i]]=userBuyAmountSum[issueIndex][userNumberIndex[i]].add(_amount);
            }
            emit Buy(msg.sender, tokenId);
        }
    }

    function  multiBuy(uint256 _price, uint8[4][] memory _numbers) public {
        require (!drawed(), 'drawed, can not buy now');
        uint256 totalPrice  = 0;
        for (uint i = 0; i < _numbers.length; i++) {
            for (uint j = 0; j < 4; j++) {
                require (_numbers[i][j] <= maxNumber, 'exceed the maximum');
            }
            uint256 tokenId = lotteryNFT.newLotteryItem(msg.sender, _numbers[i], _price, issueIndex);
            lotteryInfo[issueIndex].push(tokenId);
            if (userInfo[msg.sender].length == 0) {
                totalAddresses = totalAddresses + 1;
            }
            userInfo[msg.sender].push(tokenId);
            totalAmount = totalAmount + _price;
            lastTimestamp = block.timestamp;
            totalPrice = totalPrice + _price;
            uint64[keyLengthForEachBuy] memory numberIndexKey = generateNumberIndexKey(_numbers[i]);
            for (uint k = 0; k < keyLengthForEachBuy; k++) {
                userBuyAmountSum[issueIndex][numberIndexKey[k]]=userBuyAmountSum[issueIndex][numberIndexKey[k]].add(_price);
            }
        }
        cake.safeTransferFrom(address(msg.sender), address(this), totalPrice);
        emit MultiBuy(msg.sender, totalPrice);
    }

    function claimReward(uint256 _tokenId) public {
        require(msg.sender == lotteryNFT.ownerOf(_tokenId), "not from owner");
        require (lotteryNFT.getClaimStatus(_tokenId) == false, "claimed");
        uint256 reward = getRewardView(_tokenId);
        if(reward>0) {
            cake.safeTransfer(address(msg.sender), reward);
        }
        lotteryNFT.claimReward(_tokenId);
        emit Claim(msg.sender, _tokenId, reward);
    }

    function  multiClaim(uint256[] memory _tickets) public {
        require (drawed(), 'havnt drawed, can not claim');
        uint256 totalReward = 0;
        for (uint i = 0; i < _tickets.length; i++) {
            require (msg.sender == lotteryNFT.ownerOf(_tickets[i]), "not from owner");
            require (lotteryNFT.getClaimStatus(_tickets[i]) == false, "claimed");
            uint256 reward = getRewardView(_tickets[i]);
            if(reward>0) {
                totalReward = reward.add(totalReward);
            }
        }
        lotteryNFT.multiClaimReward(_tickets);
        if(totalReward>0) {
            cake.safeTransfer(address(msg.sender), totalReward);
        }
        emit MultiClaim(msg.sender, totalReward);
    }

    function generateNumberIndexKey(uint8[4] memory number) public pure returns (uint64[keyLengthForEachBuy] memory) {
        uint64[4] memory tempNumber;
        tempNumber[0]=uint64(number[0]);
        tempNumber[1]=uint64(number[1]);
        tempNumber[2]=uint64(number[2]);
        tempNumber[3]=uint64(number[3]);

        uint64[keyLengthForEachBuy] memory result;
        result[0] = tempNumber[0]*256*256*256*256*256*256 + 1*256*256*256*256*256 + tempNumber[1]*256*256*256*256 + 2*256*256*256+tempNumber[2]*256*256 + 3*256 + tempNumber[3];

        result[1] = tempNumber[0]*256*256*256*256 + 1*256*256*256 + tempNumber[1]*256*256 + 2*256+ tempNumber[2];
        result[2] = tempNumber[0]*256*256*256*256 + 1*256*256*256 + tempNumber[1]*256*256 + 3*256+ tempNumber[3];
        result[3] = tempNumber[0]*256*256*256*256 + 2*256*256*256 + tempNumber[2]*256*256 + 3*256 + tempNumber[3];
        result[4] = 1*256*256*256*256*256 + tempNumber[1]*256*256*256*256 + 2*256*256*256 + tempNumber[2]*256*256 + 3*256 + tempNumber[3];

        result[5] = tempNumber[0]*256*256 + 1*256+ tempNumber[1];
        result[6] = tempNumber[0]*256*256 + 2*256+ tempNumber[2];
        result[7] = tempNumber[0]*256*256 + 3*256+ tempNumber[3];
        result[8] = 1*256*256*256+ tempNumber[1]*256*256 + 2*256+ tempNumber[2];
        result[9] = 1*256*256*256+ tempNumber[1]*256*256 + 3*256+ tempNumber[3];
        result[10] = 2*256*256*256+ tempNumber[2]*256*256 + 3*256+ tempNumber[3];

        return result;
    }

    function calculateMatchingRewardAmount() public view returns (uint256[4] memory) {
        uint64[keyLengthForEachBuy] memory numberIndexKey = generateNumberIndexKey(winningNumbers);

        uint256 totalAmout1 = userBuyAmountSum[issueIndex][numberIndexKey[0]];

        uint256 sumForTotalAmout2 = userBuyAmountSum[issueIndex][numberIndexKey[1]];
        sumForTotalAmout2 = sumForTotalAmout2.add(userBuyAmountSum[issueIndex][numberIndexKey[2]]);
        sumForTotalAmout2 = sumForTotalAmout2.add(userBuyAmountSum[issueIndex][numberIndexKey[3]]);
        sumForTotalAmout2 = sumForTotalAmout2.add(userBuyAmountSum[issueIndex][numberIndexKey[4]]);

        uint256 totalAmout2 = sumForTotalAmout2.sub(totalAmout1.mul(4));

        uint256 sumForTotalAmout3 = userBuyAmountSum[issueIndex][numberIndexKey[5]];
        sumForTotalAmout3 = sumForTotalAmout3.add(userBuyAmountSum[issueIndex][numberIndexKey[6]]);
        sumForTotalAmout3 = sumForTotalAmout3.add(userBuyAmountSum[issueIndex][numberIndexKey[7]]);
        sumForTotalAmout3 = sumForTotalAmout3.add(userBuyAmountSum[issueIndex][numberIndexKey[8]]);
        sumForTotalAmout3 = sumForTotalAmout3.add(userBuyAmountSum[issueIndex][numberIndexKey[9]]);
        sumForTotalAmout3 = sumForTotalAmout3.add(userBuyAmountSum[issueIndex][numberIndexKey[10]]);

        uint256 totalAmout3 = sumForTotalAmout3.add(totalAmout1.mul(6)).sub(sumForTotalAmout2.mul(3));

        return [totalAmount, totalAmout1, totalAmout2, totalAmout3];
    }

    function getMatchingRewardAmount(uint256 _issueIndex, uint256 _matchingNumber) public view returns (uint256) {
        return historyAmount[_issueIndex][5 - _matchingNumber];
    }

    function getTotalRewards(uint256 _issueIndex) public view returns(uint256) {
        require (_issueIndex <= issueIndex, '_issueIndex <= issueIndex');

        if(!drawed() && _issueIndex == issueIndex) {
            return totalAmount;
        }
        return historyAmount[_issueIndex][0];
    }

    function getRewardView(uint256 _tokenId) public view returns(uint256) {
        uint256 _issueIndex = lotteryNFT.getLotteryIssueIndex(_tokenId);
        uint8[4] memory lotteryNumbers = lotteryNFT.getLotteryNumbers(_tokenId);
        uint8[4] memory _winningNumbers = historyNumbers[_issueIndex];
        uint256 matchingNumber = 0;
        for (uint i = 0; i < lotteryNumbers.length; i++) {
            if (_winningNumbers[i] == lotteryNumbers[i]) {
                matchingNumber= matchingNumber +1;
            }
        }
        uint256 reward = 0;
        if (matchingNumber > 1) {
            uint256 amount = lotteryNFT.getLotteryAmount(_tokenId);
            uint256 poolAmount = getTotalRewards(_issueIndex).mul(allocation[4-matchingNumber]).div(100);
            reward = amount.mul(1e12).div(getMatchingRewardAmount(_issueIndex, matchingNumber)).mul(poolAmount);
        }
        return reward.div(1e12);
    }


    // Update admin address by the previous dev.
    function setAdmin(address _adminAddress) public onlyOwner {
        adminAddress = _adminAddress;
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function adminWithdraw(uint256 _amount) public onlyOwner {
        cake.safeTransfer(address(msg.sender), _amount);
        emit DevWithdraw(msg.sender, _amount);
    }
}