// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {Sapphire} from "@oasisprotocol/sapphire-contracts/contracts/Sapphire.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

type WorkerId is bytes32;

interface IIdentityAuthorizer is IERC165 {
    function canAssumeIdentity(
        WorkerId _id,
        bytes calldata _context,
        bytes calldata _authz
    ) external returns (bool);
}

contract WorkerRegistry {
    /// The identified worker is not registered.
    error NoSuchWorker(); // bd88a936 vYipNg==
    /// The action is disallowed.
    error Unauthorized(); // 82b42900 grQpAA==

    event WorkerRegistered(WorkerId id);
    event WorkerDeregistered(WorkerId indexed id);

    mapping(WorkerId => address) internal registrants;
    mapping(WorkerId => address) internal proposedRegistrants;
    mapping(WorkerId => IIdentityAuthorizer) internal authorizers;

    modifier onlyRegistrant(WorkerId _id) {
        if (msg.sender != registrants[_id]) revert Unauthorized();
        _;
    }

    function registerWorker(
        address _authorizer,
        bytes calldata _entropy
    ) external returns (WorkerId id) {
        require(
            ERC165Checker.supportsInterface(_authorizer, type(IIdentityAuthorizer).interfaceId),
            "not IIdentityAuthorizer"
        );
        id = _generateWorkerId(_entropy);
        require(registrants[id] == address(0), "unlucky");
        registrants[id] = msg.sender;
        authorizers[id] = IIdentityAuthorizer(_authorizer);
        emit WorkerRegistered(id);
    }

    function deregisterWorker(WorkerId _id) external onlyRegistrant(_id) {
        delete registrants[_id];
        delete proposedRegistrants[_id];
        delete authorizers[_id];
        emit WorkerDeregistered(_id);
    }

    function proposeRegistrationTransfer(WorkerId _id, address _to) external onlyRegistrant(_id) {
        proposedRegistrants[_id] = _to;
    }

    function acceptRegistrationTransfer(WorkerId _id) external {
        address proposed = proposedRegistrants[_id];
        if (msg.sender != proposed) revert Unauthorized();
        registrants[_id] = proposed;
        delete proposedRegistrants[_id];
    }

    function getAuthorizer(WorkerId _id) external view returns (IIdentityAuthorizer) {
        IIdentityAuthorizer authorizer = authorizers[_id];
        if (address(authorizer) == address(0)) revert NoSuchWorker();
        return authorizer;
    }

    function _generateWorkerId(bytes calldata _pers) internal view returns (WorkerId) {
        return
            WorkerId.wrap(
                block.chainid == 0x5aff || block.chainid == 0x5afe
                    ? bytes32(Sapphire.randomBytes(16, _pers))
                    : keccak256(bytes.concat(bytes32(block.prevrandao), _pers))
            );
    }
}