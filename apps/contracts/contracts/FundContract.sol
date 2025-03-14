// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "hardhat/console.sol";
import "./WFRToken.sol";
import "./interfaces/IStrategy.sol";

contract FundContract is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC20Upgradeable
{
    struct StrategyInfo {
        address strategyAddress;
        string strategyName;
        uint256 strategyWeight;
        uint256 value;
    }

    IERC20 public usdc;
    WFRToken public wfrToken;
    IStrategy[] public strategies;
    uint256[] public strategyWeights;

    // The principle of the fund we don't charge fees on as
    // it didn't have any gains yet
    // or we charged fees on it already
    uint256 public fundPrincipleAfterFees;
    uint256 public protocolFee;
    address public treasury;
    address public treasuryManager;

    struct RedemptionRequest {
        address user;
        uint256 amount;
    }

    RedemptionRequest[] public redemptionQueue;

    mapping(address => bool) public whitelisted;

    modifier onlyWhitelisted() {
        require(
            owner() == msg.sender ||
                whitelisted[msg.sender] ||
                address(this) == msg.sender,
            "Not allowed"
        );
        _;
    }

    modifier onlyTreasuryManager() {
        require(
            msg.sender == treasuryManager || msg.sender == owner(),
            "Not allowed"
        );
        _;
    }

    function initialize(address _usdc, address _wfrToken) external initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __ERC20_init("Wafra Fund", "WFRF");

        usdc = IERC20(_usdc);
        wfrToken = WFRToken(_wfrToken);
        protocolFee = 10; // Default protocol fee
        whitelisted[msg.sender] = true;
        treasury = msg.sender; // Default treasury is contract deployer
    }

    function setProtocolFee(uint256 _fee) external onlyOwner {
        require(_fee <= 100, "Fee too high");
        protocolFee = _fee;
    }

    //--------------------------------------------------------------------------
    // Access Control
    //--------------------------------------------------------------------------

    function setWhitelist(address _addr, bool _allowed) external onlyOwner {
        require(_addr != address(0), "Invalid address");
        whitelisted[_addr] = _allowed;
    }

    function setTreasuryManager(address _manager) external onlyOwner {
        require(_manager != address(0), "Invalid address");
        treasuryManager = _manager;
    }

    function updateTreasury(address _newTreasury) external onlyTreasuryManager {
        require(_newTreasury != address(0), "Invalid address");
        treasury = _newTreasury;
    }

    //--------------------------------------------------------------------------
    // Strategy Management
    //--------------------------------------------------------------------------

    function addStrategy(
        address _strategy,
        uint256 _weight
    ) external onlyWhitelisted {
        try IStrategy(_strategy).strategyName() returns (string memory) {
            // Strategy interface exists
        } catch {
            revert("Invalid strategy implementation");
        }
        try IStrategy(_strategy).totalValue() returns (uint256) {
            // Strategy interface exists
        } catch {
            revert("Invalid strategy implementation");
        }
        strategies.push(IStrategy(_strategy));
        strategyWeights.push(_weight);
    }

    function setStrategyWeights(
        uint256[] calldata _weights
    ) external onlyWhitelisted {
        require(_weights.length == strategies.length, "Length mismatch");
        uint256 total;
        for (uint256 i = 0; i < _weights.length; i++) {
            total += _weights[i];
        }
        require(total > 0, "Invalid weights");

        for (uint256 j = 0; j < _weights.length; j++) {
            strategyWeights[j] = _weights[j];
        }
    }

    // @notice should only be usedd off chain as high gas cost
    function getStrategies() external view returns (StrategyInfo[] memory) {
        require(strategies.length == strategyWeights.length, "Not configured");

        StrategyInfo[] memory result = new StrategyInfo[](strategies.length);
        for (uint256 i = 0; i < strategies.length; i++) {
            result[i] = StrategyInfo({
                strategyAddress: address(strategies[i]),
                strategyName: strategies[i].strategyName(),
                strategyWeight: strategyWeights[i],
                value: strategies[i].totalValue()
            });
        }
        return result;
    }

    function removeStrategies(
        uint256[] calldata indexes
    ) external onlyWhitelisted {
        require(indexes.length > 0, "No indexes provided");

        for (uint256 i = 0; i < indexes.length; i++) {
            require(indexes[i] < strategies.length, "Index out of range");
            strategies[indexes[i]] = strategies[strategies.length - 1];
            strategies.pop();
            strategyWeights[indexes[i]] = strategyWeights[
                strategyWeights.length - 1
            ];
            strategyWeights.pop();
        }
    }

    //--------------------------------------------------------------------------
    // Deposit
    //--------------------------------------------------------------------------

    function _deposit(uint256 amount, address userAddress) internal {
        require(amount > 0, "Invalid deposit");
        require(userAddress != address(0), "Invalid user address");

        // Transfer USDC to the contract
        usdc.transferFrom(msg.sender, address(this), amount);

        // Mint WFR tokens to the user
        _mintWFRForDeposit(amount, userAddress);

        // Update the principle of the fund we don't charge fees on
        fundPrincipleAfterFees += amount;

        emit Deposit(msg.sender, amount, userAddress);
    }

    /**
     * @dev Deposits USDC into the fund, mints WFR tokens based on fund share price
     */
    function deposit(uint256 amount) external nonReentrant {
        _deposit(amount, msg.sender);
    }

    /**
     * @dev Deposits USDC into the fund, mints WFR tokens based on fund share price
     * @param amount The amount of USDC to deposit
     * @param receiverAddress The address to mint WFR tokens to
     */
    function depositTo(
        uint256 amount,
        address receiverAddress
    ) external nonReentrant {
        _deposit(amount, receiverAddress);
    }

    function _mintWFRForDeposit(
        uint256 depositAmount,
        address account
    ) internal {
        uint256 fundValue = totalValue() - depositAmount;
        uint256 currentSupply = wfrToken.totalSupply();

        uint256 sharesToMint;
        if (currentSupply == 0 || fundValue == 0) {
            // If first deposit or no value, mint 1:1
            sharesToMint = depositAmount;
        } else {
            // we need to multiply by 1e18 to avoid precision loss
            sharesToMint = (depositAmount * currentSupply * 1e18) / fundValue / 1e18; 
        }
        if (sharesToMint == 0) {
            revert(string.concat(
                "Shares to mint is 0. Supply: ", 
                Strings.toString(currentSupply),
                " Value: ",
                Strings.toString(fundValue),
                " Deposit: ",
                Strings.toString(depositAmount)
            ));
        }

        wfrToken.mint(account, sharesToMint);
    }

    //--------------------------------------------------------------------------
    // Deploy Capital
    //--------------------------------------------------------------------------

    /**
     * @dev Deploys contract USDC to each strategy according to strategyWeights
     */
    function deployCapital() external onlyWhitelisted nonReentrant {
        require(
            strategies.length == strategyWeights.length,
            "strategies not configured properly"
        );

        uint256 totalCapital = usdc.balanceOf(address(this));
        for (uint256 i = 0; i < strategies.length; i++) {
            totalCapital += strategies[i].totalValue();
        }

        uint256 totalWeight = 0;
        for (uint256 w = 0; w < strategyWeights.length; w++) {
            totalWeight += strategyWeights[w];
        }
        if (totalWeight == 0) {
            return;
        }

        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 desired = (totalCapital * strategyWeights[i]) / totalWeight;
            uint256 current = strategies[i].totalValue();
            if (current > desired) {
                strategies[i].withdraw(current - desired, address(this));
            }
        }

        uint256 remaining = usdc.balanceOf(address(this));
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 desired = (totalCapital * strategyWeights[i]) / totalWeight;
            uint256 current = strategies[i].totalValue();
            if (current < desired) {
                uint256 toDeposit = desired - current;
                if (toDeposit > remaining) {
                    toDeposit = remaining;
                }
                if (toDeposit > 0) {
                    usdc.approve(address(strategies[i]), toDeposit);
                    strategies[i].deposit(toDeposit);
                    remaining -= toDeposit;
                }
            }
        }
    }

    //--------------------------------------------------------------------------
    // Redemption
    //--------------------------------------------------------------------------

    // @dev calculate the amount of WFR tokens that would be minted for a given amount of USDC
    function wfrAmount(uint256 amount) public view returns (uint256) {
        return (amount * wfrToken.totalSupply()) / totalValue();
    }

    /**
     * @dev User requests redemption by transferring WFR tokens into this contract.
     *      The tokens remain locked here until redeemed in a batch by `processRedemptionsBatch`.
     */
    function requestRedemption(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(wfrToken.balanceOf(msg.sender) >= amount, "Insufficient WFR");

        wfrToken.transferFrom(msg.sender, address(this), amount);

        redemptionQueue.push(RedemptionRequest(msg.sender, amount));

        emit RedemptionRequested(msg.sender, amount, redemptionQueue.length - 1);
    }

    /**
     * @dev Processes redemptions after ensuring fees are collected
     */
    function processRedemptionsBatch(
        uint256 start,
        uint256 batchSize
    ) external onlyWhitelisted nonReentrant {
        if (redemptionQueue.length == 0) return;

        // First collect any pending fees
        uint256 currentValue = totalValue();
        if (currentValue > fundPrincipleAfterFees) {
            this.collectProtocolFees();
        }

        require(start < redemptionQueue.length, "Start out of range");
        uint256 end = start + batchSize;
        if (end > redemptionQueue.length) {
            end = redemptionQueue.length;
        }

        uint256 _totalSupply = wfrToken.totalSupply();
        require(_totalSupply > 0, "No WFR tokens exist");

        // if redemption total is greater then usdc balance, withdraw
        uint256 totalRedemptionWfr = 0;
        for (uint256 i = start; i < end; i++) {
            totalRedemptionWfr += redemptionQueue[i].amount;
        }
        uint256 totalRedemptionValue = (currentValue * totalRedemptionWfr) /
            _totalSupply;

        if (totalRedemptionValue > usdc.balanceOf(address(this))) {
            _withdrawFromStrategies(
                totalRedemptionValue - usdc.balanceOf(address(this))
            );
        }

        // Process each redemption without taking additional fees
        address[] memory processedRedemptions = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            RedemptionRequest memory request = redemptionQueue[i];
            // storing to emit as event
            processedRedemptions[i - start] = request.user;
            if (request.amount == 0) continue; // Skip already processed requests

            uint256 userValue = (currentValue * request.amount) / _totalSupply;

            // Burn tokens and transfer USDC
            wfrToken.burn(address(this), request.amount);
            usdc.transfer(request.user, userValue);
            redemptionQueue[i].amount = 0;
        }

        // Update fundPrincipleAfterFees to reflect redemptions
        fundPrincipleAfterFees = totalValue();

        emit RedemptionProcessed(start, end, processedRedemptions);
    }

    // the queue can grow for a while and will increase gas costs
    // here we are timming the length
    function trimRedemptionQueue() external onlyWhitelisted {
        uint256 i = 0;
        while (i < redemptionQueue.length) {
            if (redemptionQueue[i].amount == 0) {
                redemptionQueue[i] = redemptionQueue[
                    redemptionQueue.length - 1
                ];
                redemptionQueue.pop();
            } else {
                i++;
            }
        }
    }

    //--------------------------------------------------------------------------
    // ERC20 Overrides
    //--------------------------------------------------------------------------

    function name() public pure override returns (string memory) {
        return "Wafra Fund";
    }

    function symbol() public pure override returns (string memory) {
        return "WFRF";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function totalSupply() public view override returns (uint256) {
        return totalValue();
    }

    function balanceOf(address account) public view override returns (uint256) {
        return (wfrToken.balanceOf(account) * totalValue()) / wfrToken.totalSupply();
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        uint256 senderBalance = balanceOf(msg.sender);
        require(senderBalance >= amount, "Insufficient balance");

        uint256 shares = (amount * wfrToken.totalSupply()) / totalValue();
        wfrToken.burn(msg.sender, shares);
        wfrToken.mint(recipient, shares);

        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        uint256 senderBalance = balanceOf(sender);
        require(senderBalance >= amount, "Insufficient balance");

        uint256 currentAllowance = wfrToken.allowance(sender, msg.sender);
        require(currentAllowance >= amount, "Insufficient allowance");

        uint256 shares = (amount * wfrToken.totalSupply()) / totalValue();
        wfrToken.burn(sender, shares);
        wfrToken.mint(recipient, shares);

        return true;
    }

    //--------------------------------------------------------------------------
    // Fee Calculation (Separate from Redemption)
    //--------------------------------------------------------------------------

    function totalValue() public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            total += strategies[i].totalValue();
        }
        total += usdc.balanceOf(address(this));
        return total;
    }

    /**
     * @dev Collects protocol fees on any new gains since last collection
     * @return feeAmount The amount of fees collected
     */
    function collectProtocolFees() external onlyWhitelisted returns (uint256) {
        uint256 currentValue = totalValue();
        require(
            currentValue > fundPrincipleAfterFees,
            "No new gains to collect"
        );

        // Calculate new gains since last fee collection
        uint256 newGains = currentValue - fundPrincipleAfterFees;

        // Calculate fee amount
        uint256 feeAmount = (newGains * protocolFee) / 100;

        // Calculate shares to mint
        uint256 _totalSupply = wfrToken.totalSupply();
        uint256 sharesToMint = (feeAmount * _totalSupply) / currentValue;

        // Mint to treasury this dilutes everyone proportionally
        // This has the same effect as withdrawing the fee and sending it to the treasury
        wfrToken.mint(treasury, sharesToMint);

        // Update tracking
        fundPrincipleAfterFees = currentValue;

        emit ProtocolFeesCollected(feeAmount, sharesToMint, treasury);
        return sharesToMint;
    }

    //--------------------------------------------------------------------------
    // Internal Helpers
    //--------------------------------------------------------------------------

    function _withdrawFromStrategies(uint256 amount) internal {
        uint256 remaining = amount;
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < strategies.length; i++) {
            totalWeight += strategyWeights[i];
        }

        // withdraw from the strats according to weights
        for (uint256 i = 0; i < strategies.length; i++) {
            if (remaining == 0) break;
            uint256 reversedIndex = strategies.length - 1 - i;
            uint256 stratValue = strategies[reversedIndex].totalValue();
            if (stratValue == 0) continue;

            uint256 weightedWithdraw = (strategyWeights[reversedIndex] *
                amount) / totalWeight;
            if (weightedWithdraw >= remaining) {
                weightedWithdraw = remaining;
            }
            if (weightedWithdraw > stratValue) {
                weightedWithdraw = stratValue;
            }

            if (weightedWithdraw > 0) {
                strategies[reversedIndex].withdraw(
                    weightedWithdraw,
                    address(this)
                );
                remaining -= weightedWithdraw;
            }
        }

        if (remaining == 0) return;

        // now take the rest linearly from the strats
        for (uint256 i = 0; i < strategies.length; i++) {
            uint256 stratValue = strategies[i].totalValue();
            if (stratValue == 0) continue;
            if (stratValue >= remaining) {
                strategies[i].withdraw(remaining, address(this));
                remaining = 0;
                break;
            }
            strategies[i].withdraw(stratValue, address(this));
            remaining -= stratValue;
        }

        if (remaining > 0) {
            revert("Insufficient funds in strategies");
        }
    }

    //--------------------------------------------------------------------------
    // UUPS Upgrade
    //--------------------------------------------------------------------------

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    function upgradeToken(address newImplementation) external onlyOwner {
        UUPSUpgradeable(address(wfrToken)).upgradeToAndCall(
            newImplementation,
            ""
        );
    }

    //--------------------------------------------------------------------------
    // Queries
    //--------------------------------------------------------------------------

    /**
     * @dev Returns the current gains that haven't had fees taken yet
     */
    function getPendingFees() external view returns (uint256) {
        uint256 currentValue = totalValue();
        if (currentValue <= fundPrincipleAfterFees) return 0;

        uint256 newGains = currentValue - fundPrincipleAfterFees;
        return (newGains * protocolFee) / 100;
    }

    /**
     * @dev Returns the current redemption queue
     */
    function getRedemptionQueue()
        external
        view
        returns (RedemptionRequest[] memory)
    {
        return redemptionQueue;
    }

    /**
     * Events
     */

    event ProtocolFeesCollected(
        uint256 feeAmount,
        uint256 sharesToMint,
        address treasury
    );
    event Deposit(address indexed user, uint256 amount, address receiver);
    event RedemptionProcessed(uint256 start, uint256 end, address[] processedRedemptions);
    event RedemptionRequested(address indexed user, uint256 amount, uint256 index);
}
