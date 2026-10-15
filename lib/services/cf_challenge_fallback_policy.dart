enum CfChallengeFallbackAction {
  showNoChallenge,
  revealChallenge,
  checkCurrentPage,
}

CfChallengeFallbackAction decideCfChallengeFallback({
  required int probeGeneration,
  required int loadGeneration,
  required bool hasActiveChallenge,
}) {
  if (probeGeneration != loadGeneration) {
    return CfChallengeFallbackAction.checkCurrentPage;
  }
  if (hasActiveChallenge) {
    return CfChallengeFallbackAction.revealChallenge;
  }
  return CfChallengeFallbackAction.showNoChallenge;
}
