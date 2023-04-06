import Cycles "mo:base/ExperimentalCycles";
import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Result "mo:base/Result";
import Int "mo:base/Int";
import Time "mo:base/Time";
import Timer "mo:base/Timer";
import Debug "mo:base/Debug";
import Random "mo:base/Random";
import Nat "mo:base/Nat";

import Canistergeek "mo:canistergeek/canistergeek";
import Cap "mo:cap/Cap";

import Assets "CanisterAssets";
import AssetsTypes "CanisterAssets/types";
import EXT "Ext";
import EXTTypes "Ext/types";
import ExtCore "./toniq-labs/ext/Core";
import Http "Http";
import HttpTypes "Http/types";
import Marketplace "Marketplace";
import MarketplaceTypes "Marketplace/types";
import Sale "Sale";
import SaleTypes "Sale/types";
import Shuffle "Shuffle";
import ShuffleTypes "Shuffle/types";
import TokenTypes "Tokens/types";
import Tokens "Tokens";
import Disburser "Disburser";
import DisburserTypes "Disburser/types";
import Utils "./utils";
import Env "./Env";
import Types "./types";

shared ({ caller = init_minter }) actor class Canister(cid : Principal, initArgs: Types.InitArgs) = myCanister {

  let config = {
    initArgs with
    canister = cid;
    minter = init_minter;
  };

  /*********
  * TYPES *
  *********/
  type AccountIdentifier = ExtCore.AccountIdentifier;
  type SubAccount = ExtCore.SubAccount;

  type StableChunk = {
    #v1: {
      tokens : TokenTypes.StableChunk;
      sale : SaleTypes.StableChunk;
      marketplace : MarketplaceTypes.StableChunk;
      assets : AssetsTypes.StableChunk;
      shuffle : ShuffleTypes.StableChunk;
      disburser : DisburserTypes.StableChunk;
    };
  };

  /****************
  * STABLE STATE *
  ****************/

  stable var _stableChunks : [var StableChunk] = [var];

  // Cap
  private stable var rootBucketId : ?Text = null;

  // Canistergeek
  stable var _canistergeekMonitorUD : ?Canistergeek.UpgradeData = null;

  // timers
  stable var _timerId = 0;
  stable var _revealTimerId = 0;

  // State functions
  system func preupgrade() {
    let chunkSize = 100_000;

    _stableChunks := Array.tabulateVar<StableChunk>(_getChunkCount(chunkSize), func(i : Nat) {
      _toStableChunk(chunkSize, i);
    });

    // Canistergeek
    _canistergeekMonitorUD := ?canistergeekMonitor.preupgrade();
  };

  system func postupgrade() {
    // Canistergeek
    canistergeekMonitor.postupgrade(_canistergeekMonitorUD);
    _canistergeekMonitorUD := null;

    for (i in _stableChunks.keys()) {
      _loadStableChunk(_stableChunks[i]);
    };
    _stableChunks := [var];

    _setTimers();
  };

  func _getChunkCount(chunkSize : Nat) : Nat {
    var count = Nat.max(1, _Marketplace.getChunkCount(chunkSize));
    count := Nat.max(count, _Sale.getChunkCount(chunkSize));
    count;
  };

  func _toStableChunk(chunkSize : Nat, chunkIndex : Nat) : StableChunk {
    #v1({
      tokens = _Tokens.toStableChunk(chunkSize, chunkIndex);
      sale = _Sale.toStableChunk(chunkSize, chunkIndex);
      marketplace = _Marketplace.toStableChunk(chunkSize, chunkIndex);
      assets = _Assets.toStableChunk(chunkSize, chunkIndex);
      shuffle = _Shuffle.toStableChunk(chunkSize, chunkIndex);
      disburser = _Disburser.toStableChunk(chunkSize, chunkIndex);
    });
  };

  func _loadStableChunk(chunk : StableChunk) {
    switch (chunk) {
      case (#v1(data)) {
        _Tokens.loadStableChunk(data.tokens);
        _Sale.loadStableChunk(data.sale);
        _Marketplace.loadStableChunk(data.marketplace);
        _Assets.loadStableChunk(data.assets);
        _Shuffle.loadStableChunk(data.shuffle);
        _Disburser.loadStableChunk(data.disburser);
      };
    };
  };

  // backup
  public query func getChunkCount(chunkSize : Nat) : async Nat {
    _getChunkCount(chunkSize);
  };

  public query func backupChunk(chunkSize : Nat, chunkIndex : Nat) : async StableChunk {
    _toStableChunk(chunkSize, chunkIndex);
  };

  public shared ({ caller }) func restoreChunk(chunk : StableChunk): async () {
    assert (caller == init_minter);
    if (not Env.restoreEnabled) {
      Debug.trap("Restore disabled. Please reinstall canister with 'restoreEnabled = true'");
    };
    _loadStableChunk(chunk);
  };

  func _trapIfRestoreEnabled() {
    if (Env.restoreEnabled) {
      Debug.trap("Restore in progress. If restore is complete, upgrade canister with `restoreEnabled = false`");
    };
  };

  // timers
  func _setTimers() {
    Timer.cancelTimer(_timerId);
    Timer.cancelTimer(_revealTimerId);

    _timerId := Timer.recurringTimer(Env.timersInterval, func(): async () {
      ignore cronSettlements();
      ignore cronDisbursements();
      ignore cronSalesSettlements();
      ignore cronFailedSales();
    });

    if (config.delayedReveal and not _Shuffle.isShuffled()) {
      let revealTime = config.publicSaleStart + config.revealDelay;
      let delay = Int.abs(Int.max(0, revealTime - Time.now()));

      // add random delay up to 60 minutes
      let minute = 1_000_000_000 * 60;
      let randDelay = Int.abs(Time.now() % 60 * minute);

      _revealTimerId := Timer.setTimer(#nanoseconds(delay + randDelay), func(): async () {
        ignore _Shuffle.shuffleAssets();
      });
    };
  };

  /*************
  * CONSTANTS *
  *************/

  let CREATION_CYCLES : Nat = 1_000_000_000_000;

  /***********
  * CLASSES *
  ***********/

  // Canistergeek
  private let canistergeekMonitor = Canistergeek.Monitor();

  /**
    * Returns canister information based on passed parameters.
    * Called from browser.
    */
  public query ({ caller }) func getCanistergeekInformation(request : Canistergeek.GetInformationRequest) : async Canistergeek.GetInformationResponse {
    validateCaller(caller);
    Canistergeek.getInformation(?canistergeekMonitor, null, request);
  };

  /**
    * Updates canister information based on passed parameters at current time.
    * Called from browser or any canister "update" method.
    */
  public shared ({ caller }) func updateCanistergeekInformation(request : Canistergeek.UpdateInformationRequest) : async () {
    _trapIfRestoreEnabled();
    validateCaller(caller);
    canistergeekMonitor.updateInformation(request);
  };

  private func validateCaller(principal : Principal) : () {
    assert (principal == Principal.fromText("onkyj-ezxuw-tbqva-ictbu-dhdpw-hdcj4-4wxn7-tfo77-hh6qc-b3dng-pqe"));
  };

  // Disburser
  let _Disburser = Disburser.Factory(config);

  // queries
  public query func getDisbursements() : async [DisburserTypes.Disbursement] {
    _Disburser.getDisbursements();
  };

  // updates
  public func cronDisbursements() : async () {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    await _Disburser.cronDisbursements();
  };

  // Cap
  let _Cap = Cap.Cap(null, rootBucketId);

  public shared ({ caller }) func initCap() : async Result.Result<(), Text> {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    assert (caller == init_minter);
    let pid = Principal.fromActor(myCanister);
    let tokenContractId = Principal.toText(pid);

    try {
      rootBucketId := await _Cap.handshake(
        tokenContractId,
        CREATION_CYCLES,
      );

      return #ok();
    } catch e {
      throw e;
    };
  };

  // Tokens
  let _Tokens = Tokens.Factory(config);

  // queries
  public query func balance(request : TokenTypes.BalanceRequest) : async TokenTypes.BalanceResponse {
    _Tokens.balance(request);
  };

  public query func bearer(token : TokenTypes.TokenIdentifier) : async Result.Result<TokenTypes.AccountIdentifier, TokenTypes.CommonError> {
    _Tokens.bearer(token);
  };

  // Assets
  let _Assets = Assets.Factory(config);

  public shared ({ caller }) func streamAsset(id : Nat, isThumb : Bool, payload : Blob) : async () {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    // checks caller == minter
    _Assets.streamAsset(caller, id, isThumb, payload);
  };

  public shared ({ caller }) func updateThumb(name : Text, file : AssetsTypes.File) : async ?Nat {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    // checks caller == minter
    _Assets.updateThumb(caller, name, file);
  };

  public shared ({ caller }) func addAsset(asset : AssetsTypes.Asset) : async Nat {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    // checks caller == minter
    _Assets.addAsset(caller, asset);
  };

  // Shuffle
  let _Shuffle = Shuffle.Factory(
    config,
    {
      _Assets;
      _Tokens;
    },
  );

  // Sale
  let _Sale = Sale.Factory(
    config,
    {
      _Cap;
      _Shuffle;
      _Tokens;
      _Disburser;
    },
  );

  // updates
  public shared ({ caller }) func initMint() : async Result.Result<(), Text> {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    // checks caller == minter
    // prevents double mint
    _setTimers();
    _Sale.initMint(caller);
  };

  public shared ({ caller }) func shuffleTokensForSale() : async () {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    // checks caller == minter
    await _Sale.shuffleTokensForSale(caller);
  };

  public shared ({ caller }) func airdropTokens(startIndex : Nat) : async () {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    // checks caller == minter
    _Sale.airdropTokens(caller, startIndex);
  };

  public shared ({ caller }) func enableSale() : async Nat {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    // checks caller == minter
    _Sale.enableSale(caller);
  };

  public func reserve(amount : Nat64, quantity : Nat64, address : SaleTypes.AccountIdentifier, _subaccountNOTUSED : SaleTypes.SubAccount) : async Result.Result<(SaleTypes.AccountIdentifier, Nat64), Text> {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    _Sale.reserve(amount, quantity, address, _subaccountNOTUSED);
  };

  public shared ({ caller }) func retrieve(paymentaddress : SaleTypes.AccountIdentifier) : async Result.Result<(), Text> {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    // no caller check, token will be sent to the address that was set on 'reserve'
    await _Sale.retrieve(caller, paymentaddress);
  };

  public shared ({ caller }) func cronSalesSettlements() : async () {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    await _Sale.cronSalesSettlements(caller);
  };

  public func cronFailedSales() : async () {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    await _Sale.cronFailedSales();
  };

  // queries
  public query func salesSettlements() : async [(SaleTypes.AccountIdentifier, SaleTypes.Sale)] {
    _Sale.salesSettlements();
  };

  public query func failedSales() : async [(SaleTypes.AccountIdentifier, SaleTypes.SubAccount)] {
    _Sale.failedSales();
  };

  public query func saleTransactions() : async [SaleTypes.SaleTransaction] {
    _Sale.saleTransactions();
  };

  public query func salesSettings(address : AccountIdentifier) : async SaleTypes.SaleSettings {
    _Sale.salesSettings(address);
  };

  // Marketplace
  let _Marketplace = Marketplace.Factory(
    config,
    {
      _Tokens;
      _Cap;
      _Sale;
      _Disburser;
    },
  );

  // updates

  // lock token and get address to pay
  public shared ({ caller }) func lock(tokenid : MarketplaceTypes.TokenIdentifier, price : Nat64, address : MarketplaceTypes.AccountIdentifier, subaccount : MarketplaceTypes.SubAccount, frontendIdentifier : ?Text) : async Result.Result<MarketplaceTypes.AccountIdentifier, MarketplaceTypes.CommonError> {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    // no caller check, anyone can lock
    await _Marketplace.lock(caller, tokenid, price, address, subaccount, frontendIdentifier);
  };

  // check payment and settle transfer token to user
  public shared ({ caller }) func settle(tokenid : MarketplaceTypes.TokenIdentifier) : async Result.Result<(), MarketplaceTypes.CommonError> {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    // no caller check, token will be sent to the address that was set on 'lock'
    await _Marketplace.settle(caller, tokenid);
  };

  public shared ({ caller }) func list(request : MarketplaceTypes.ListRequest) : async Result.Result<(), MarketplaceTypes.CommonError> {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    // checks caller == token_owner
    await _Marketplace.list(caller, request);
  };

  public shared ({ caller }) func cronSettlements() : async () {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    // caller will be stored to the Cap event, is that ok?
    await _Marketplace.cronSettlements(caller);
  };

  public shared ({ caller }) func putFrontend(identifier : Text, frontend : MarketplaceTypes.Frontend) : async () {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    // checks caller == minter
    _Marketplace.putFrontend(caller, identifier, frontend);
  };

  public shared ({ caller }) func deleteFrontend(identifier : Text) : async () {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    // checks caller == minter
    _Marketplace.deleteFrontend(caller, identifier);
  };

  public shared func frontends() : async [(Text, MarketplaceTypes.Frontend)] {
    _Marketplace.frontends();
  };

  public shared ({ caller }) func grow(n : Nat) : async Nat {
    assert (Env.test);
    ignore _Sale.grow(n);
    _Marketplace.grow(n);
  };

  // queries
  public query func details(token : MarketplaceTypes.TokenIdentifier) : async Result.Result<(MarketplaceTypes.AccountIdentifier, ?MarketplaceTypes.Listing), MarketplaceTypes.CommonError> {
    _Marketplace.details(token);
  };

  public query func transactions() : async [MarketplaceTypes.Transaction] {
    _Marketplace.transactions();
  };

  public query func settlements() : async [(MarketplaceTypes.TokenIndex, MarketplaceTypes.AccountIdentifier, Nat64)] {
    _Marketplace.settlements();
  };

  public query func listings() : async [(MarketplaceTypes.TokenIndex, MarketplaceTypes.Listing, MarketplaceTypes.Metadata)] {
    _Marketplace.listings();
  };

  public query func allSettlements() : async [(MarketplaceTypes.TokenIndex, MarketplaceTypes.Settlement)] {
    _Marketplace.allSettlements();
  };

  public query func stats() : async (Nat64, Nat64, Nat64, Nat64, Nat, Nat, Nat) {
    _Marketplace.stats();
  };

  public query func pendingCronJobs() : async {
    disbursements : Nat;
    failedSettlements : Nat;
  } {
    {
      disbursements = _Disburser.pendingCronJobs();
      failedSettlements = _Marketplace.pendingCronJobs();
    };
  };

  public query func toAccountIdentifier(p : Text, sa : Nat) : async AccountIdentifier {
    _Marketplace.toAccountIdentifier(p, sa);
  };

  // EXT
  let _EXT = EXT.Factory(
    config,
    {
      _Tokens;
      _Assets;
      _Marketplace;
      _Cap;
    },
  );

  // updates
  public shared ({ caller }) func transfer(request : EXTTypes.TransferRequest) : async EXTTypes.TransferResponse {
    _trapIfRestoreEnabled();
    canistergeekMonitor.collectMetrics();
    await _EXT.transfer(caller, request);
  };

  // queries
  public query func getMinter() : async Principal {
    _EXT.getMinter();
  };

  public query func extensions() : async [EXTTypes.Extension] {
    _EXT.extensions();
  };

  public query func supply() : async Result.Result<EXTTypes.Balance, EXTTypes.CommonError> {
    _EXT.supply();
  };

  public query func getRegistry() : async [(EXTTypes.TokenIndex, EXTTypes.AccountIdentifier)] {
    _EXT.getRegistry();
  };

  public query func getTokens() : async [(EXTTypes.TokenIndex, EXTTypes.Metadata)] {
    _EXT.getTokens();
  };

  public query func getTokenToAssetMapping() : async [(EXTTypes.TokenIndex, Text)] {
    _EXT.getTokenToAssetMapping();
  };

  public query func tokens(aid : EXTTypes.AccountIdentifier) : async Result.Result<[EXTTypes.TokenIndex], EXTTypes.CommonError> {
    _EXT.tokens(aid);
  };

  public query func tokens_ext(aid : EXTTypes.AccountIdentifier) : async Result.Result<[(EXTTypes.TokenIndex, ?MarketplaceTypes.Listing, ?Blob)], EXTTypes.CommonError> {
    _EXT.tokens_ext(aid);
  };

  public query func metadata(token : EXTTypes.TokenIdentifier) : async Result.Result<EXTTypes.Metadata, EXTTypes.CommonError> {
    _EXT.metadata(token);
  };

  // Http
  let _HttpHandler = Http.HttpHandler(
    config,
    {
      _Assets;
      _Marketplace;
      _Shuffle;
      _Tokens;
      _Sale;
    },
  );

  // queries
  public query func http_request(request : HttpTypes.HttpRequest) : async HttpTypes.HttpResponse {
    _HttpHandler.http_request(request);
  };

  public query func http_request_streaming_callback(token : HttpTypes.HttpStreamingCallbackToken) : async HttpTypes.HttpStreamingCallbackResponse {
    _HttpHandler.http_request_streaming_callback(token);
  };

  // cycles
  public func acceptCycles() : async () {
    canistergeekMonitor.collectMetrics();
    let available = Cycles.available();
    let accepted = Cycles.accept(available);
    assert (accepted == available);
  };

  public query func availableCycles() : async Nat {
    return Cycles.balance();
  };

};
