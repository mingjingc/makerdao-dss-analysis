pragma solidity >=0.5.12;

代码模块：
一、核心模块（Core）

二、抵押模块（Collateral）

三、Dai模块（Dai）
    包含dai.sol里的Dai Token合约和join.sol里的daijoin合约。此模块是为了让Dai能够代表所有资产Token（ETH先转为WETH Token). 

四、稳定系统模块（System Stabilizer）
    稳定系统模块是为了，在系统的资产抵押率低于清算线（清算线由goverance决定)，导致系统的稳定性受到威胁时，稳定系统模块刺激拍卖看守者依次参与债务和盈余拍卖，
获取拍卖Dai并销毁，让系统回到回到安全状态（即Dai保持与美元的锚定）。
    此模块包含Vow、Flop、Flap 三个合约
    Vow：有整个Maker协议的余额，包含系统盈余（MKR）和系统债务，它的任务是让系统回归平衡
    Flop：拍卖MKR，增发MKR，回购Dai
    Flap: 拍卖Dai，回购MKR, 销毁MKR
