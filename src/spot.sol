/// spot.sol -- Spotter

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.12;

import "./lib.sol";

interface VatLike {
    function file(bytes32, bytes32, uint) external;
}

interface PipLike {
    function peek() external returns (bytes32, bool);
}

// https://docs.makerdao.com/smart-contract-modules/core-module/spot-detailed-documentation
contract Spotter is LibNote {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address guy) external note auth { wards[guy] = 1;  }
    function deny(address guy) external note auth { wards[guy] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "Spotter/not-authorized");
        _;
    }

    // --- Data ---
    struct Ilk {
        // the contract which holds the current price of a given
        // ETh、的价格由特定合约提供
        PipLike pip;  // Price Feed
        // 清算率
        // 比如 1ETH，当前价值120美元 可借80美元，借贷率为120/80=150%
        // 若清算率为120%，也就是当1ETh，价值跌到x=96(x/80=120%)时，执行清算
        uint256 mat;  // Liquidation ratio [ray]
    }

    mapping (bytes32 => Ilk) public ilks;

    VatLike public vat;  // CDP Engine
    // value of DAI in the reference asset (e.g. $1 per DAI)
    // https://blog.makerdao.com/zh/%E5%B8%B8%E8%A7%81%E9%97%AE%E9%A2%98%E8%A7%A3%E7%AD%94-dai-%E6%98%AF%E4%BB%80%E4%B9%88/
    // Dai的价格稳定由抵押物保证，但不是绝对与美元锚定
    uint256 public par;  // ref per dai [ray]

    uint256 public live;

    // --- Events ---
    event Poke(
      bytes32 ilk,
      bytes32 val,  // [wad]
      uint256 spot  // [ray]
    );

    // --- Init ---
    constructor(address vat_) public {
        wards[msg.sender] = 1;
        vat = VatLike(vat_);
        par = ONE;
        live = 1;
    }

    // --- Math ---
    uint constant ONE = 10 ** 27;

    // https://solidity.readthedocs.io/en/v0.5.3/types.html
    // uint = uint256
    // int = int256 ， 我想是因为EVM是256位虚拟机缘故吧
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function rdiv(uint x, uint y) internal pure returns (uint z) {
        z = mul(x, ONE) / y;
    }

    // --- Administration ---
    function file(bytes32 ilk, bytes32 what, address pip_) external note auth {
        require(live == 1, "Spotter/not-live");
        if (what == "pip") ilks[ilk].pip = PipLike(pip_);
        else revert("Spotter/file-unrecognized-param");
    }
    function file(bytes32 what, uint data) external note auth {
        require(live == 1, "Spotter/not-live");
        if (what == "par") par = data;
        else revert("Spotter/file-unrecognized-param");
    }
    function file(bytes32 ilk, bytes32 what, uint data) external note auth {
        require(live == 1, "Spotter/not-live");
        if (what == "mat") ilks[ilk].mat = data;
        else revert("Spotter/file-unrecognized-param");
    }

    // --- Update value ---
    function poke(bytes32 ilk) external {
        // https://docs.makerdao.com/smart-contract-modules/oracle-module/oracle-security-module-osm-detailed-documentation
        // 喂价功能在OSM(Oracle Security Module)
        (bytes32 val, bool has) = ilks[ilk].pip.peek();
        uint256 spot = has ? rdiv(rdiv(mul(uint(val), 10 ** 9), par), ilks[ilk].mat) : 0;
        vat.file(ilk, "spot", spot);
        emit Poke(ilk, val, spot);
    }

    function cage() external note auth {
        live = 0;
    }

    /* spot模块（即spot.sol) 缺点：
        1. 如果spot因为某种原因不能更新资产清算线价格，则需要授权给新的spot更新资产清算线价格。
                当然这不是致命的，只是短时间价格停止波动
        2. 如果spot依赖于不可靠的喂价（Pip),Dai可能会贬值。极端例子：
             一个ETH价格为 现在跌到10美元/ETH，喂价是 200美元/ETH，会导致虽然贬值但因为喂价原因很多资产都不能及时清算，系统赤字扩大，
                大量Dai无法用足够的ETH销毁，Dai会贬值。
        3. 如果spot.poke()不及时调用，清算价格线没有及时更新，会导致资产提前或延迟清算
    */
}
