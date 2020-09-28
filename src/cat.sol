/// cat.sol -- Dai liquidation module

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
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

interface Kicker {
    function kick(address urn, address gal, uint256 tab, uint256 lot, uint256 bid)
        external returns (uint256);
}

interface VatLike {
    function ilks(bytes32) external view returns (
        uint256 Art,  // [wad]
        uint256 rate, // [ray]
        uint256 spot, // [ray]
        uint256 line, // [rad]
        uint256 dust  // [rad]
    );
    function urns(bytes32,address) external view returns (
        uint256 ink,  // [wad]
        uint256 art   // [wad]
    );
    function grab(bytes32,address,address,address,int256,int256) external;
    function hope(address) external;
    function nope(address) external;
}

interface VowLike {
    function fess(uint256) external;
}

// 清算代理
contract Cat is LibNote {
    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external note auth { wards[usr] = 1; }
    function deny(address usr) external note auth { wards[usr] = 0; }
    modifier auth {
        require(wards[msg.sender] == 1, "Cat/not-authorized");
        _;
    }

    // --- Data ---
    struct Ilk {
        // 拍卖合约地址
        address flip;  // Liquidator
        // 清算罚款
        uint256 chop;  // Liquidation Penalty  [wad]
        // 一次可最大可拍卖的资产
        uint256 dunk;  // Liquidation Quantity [rad]
    }

    mapping (bytes32 => Ilk) public ilks;

    uint256 public live;   // Active Flag
    VatLike public vat;    // CDP Engine
    VowLike public vow;    // Debt Engine
    uint256 public box;    // Max Dai out for liquidation        [rad]
    uint256 public litter; // Balance of Dai out for liquidation [rad]

    // --- Events ---
    event Bite(
      bytes32 indexed ilk,
      address indexed urn,
      uint256 ink,
      uint256 art,
      uint256 tab,
      address flip,
      uint256 id
    );

    // --- Init ---
    constructor(address vat_) public {
        wards[msg.sender] = 1;
        vat = VatLike(vat_);
        live = 1;
    }

    // --- Math ---
    uint256 constant WAD = 10 ** 18;

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        if (x > y) { z = y; } else { z = x; }
    }
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Administration ---
    function file(bytes32 what, address data) external note auth {
        if (what == "vow") vow = VowLike(data);
        else revert("Cat/file-unrecognized-param");
    }
    function file(bytes32 what, uint256 data) external note auth {
        if (what == "box") box = data;
        else revert("Cat/file-unrecognized-param");
    }
    function file(bytes32 ilk, bytes32 what, uint256 data) external note auth {
        if (what == "chop") ilks[ilk].chop = data;
        else if (what == "dunk") ilks[ilk].dunk = data;
        else revert("Cat/file-unrecognized-param");
    }
    function file(bytes32 ilk, bytes32 what, address flip) external note auth {
        if (what == "flip") {
            vat.nope(ilks[ilk].flip);
            ilks[ilk].flip = flip;
            vat.hope(flip);
        }
        else revert("Cat/file-unrecognized-param");
    }

    // --- CDP Liquidation 清算 ---
    // bite会检查 Vault 资产是否贬值到不安全线，若是则执行资产清算，拍卖资产归还所借的Dai。
    // 比如 小明借了80Dai，抵押了1 ETH，之后ETH贬值，系统会把1ETH进行拍卖，将拍卖获得的Dai，销毁80Dai并扣除相关手续费和罚款等，
    // 若有剩余ETH，则归还小明；若拍卖的全部ETH都无法低小明借的80Dai，系统安全模块会销毁预备的Dai，保证Dai的价格稳定性。当然若还无法偿还，Dai则有贬值风险
    //  It checks if the Vault is in an unsafe position and if it is, it starts a Flip auction for 
    // a piece of the collateral to cover a share of the debt.
    function bite(bytes32 ilk, address urn) external returns (uint256 id) {
        // 获取资产类型ilk的抵押率、清算线、Debt Floor 
        (,uint256 rate,uint256 spot,,uint256 dust) = vat.ilks(ilk);
        // 获取某个用户地址下的特定资产数量、债务
        (uint256 ink, uint256 art) = vat.urns(ilk, urn);

        require(live == 1, "Cat/not-live");
        // require the Vault to be unsafe (see definition above).
        // A Vault is unsafe when its locked collateral (ink) times its collateral's liquidation price (spot) is 
        // less than its debt (art times the fee for the collateral rate). Liquidation price is the oracle-reported 
        // price scaled by the collateral's liquidation ratio.
        // 检查某个用户的资产是否有资不抵债的风险趋势
        // 案例出自：https://www.bilibili.com/video/BV12K4y1C75H?t=680
        // 案例：ETH在某个时间点价格为180美元，小明抵押1ETH，总资产也为1ETH，可借100 Dai，抵押率为180/100=180%。
        //      假设清算线的抵押率为120%，在某个时间点ETH价格暴跌到119美元，小明的抵押率也就变为120/100=119%，
        //      所以可以清算拍卖小明的资产
        //   对下面的公式大致为： 1 ETH * 119 < 100 * 120%
        // 有所不太一样，实际rate是固定的，通过调节spot。我的理解：ETH资产是波动的，spot应该是给的一个安全值，评估ETH安全对应多少美元（市场价格毕竟是大波动）
        // 比如： 1 ETH当前价格是120美元，但可能会短时间暴跌，经过评估，暂时将ETH的安全价格定位80美元
        require(spot > 0 && mul(ink, spot) < mul(art, rate), "Cat/not-unsafe");

        Ilk memory milk = ilks[ilk];
        uint256 dart;
        {
            uint256 room = sub(box, litter);

            // test whether the remaining space in the litterbox is dusty
            require(litter < box && room >= dust, "Cat/liquidation-limit-hit");
 
            // dart 需要这次拍卖偿还的债务，应当不大于用户地址下特定资产的债务，不大于此类资产所要偿还的债务，不大于单次拍卖资产数量限制
            dart = min(art, mul(min(milk.dunk, room), WAD) / rate / milk.chop);
        }

        uint256 dink = min(ink, mul(ink, dart) / art);

        require(dart >  0      && dink >  0     , "Cat/null-auction");
        require(dart <= 2**255 && dink <= 2**255, "Cat/overflow"    );

        // This may leave the CDP in a dusty state
        vat.grab(
            ilk, urn, address(this), address(vow), -int256(dink), -int256(dart)
        );
        vow.fess(mul(dart, rate));

        {   // Avoid stack too deep
            // This calcuation will overflow if dart*rate exceeds ~10^14,
            // i.e. the maximum dunk is roughly 100 trillion DAI.
            // tab = debt + stability fee + liquidation penalty
            uint256 tab = mul(mul(dart, rate), milk.chop) / WAD;
            // litter 记录已知需要偿还的总债务，将要偿还的债务
            // 每启动一个拍卖，都会计算需要偿还的Dai，litter记录下总数，每次拍卖结束
            litter = add(litter, tab);

            // 启动拍卖
            // tab: 需要偿还的总债务
            // gal: vow合约作为接收拍卖获得的Dai
            // bid: 0 表示为公开拍卖
            // 
            id = Kicker(milk.flip).kick({
                urn: urn,
                gal: address(vow),
                tab: tab,
                lot: dink,
                bid: 0
            });
        }

        emit Bite(ilk, urn, dink, dart, mul(dart, rate), milk.flip, id);
    }

    function claw(uint256 rad) external note auth {
        litter = sub(litter, rad);
    }

    // once live=0 it cannot be set back to 1， 
    function cage() external note auth {
        live = 0;
    }
}
