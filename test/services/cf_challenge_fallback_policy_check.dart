import 'dart:async';

import '../../lib/services/cf_challenge_fallback_policy.dart';

typedef FallbackDecider = String Function({
  required int probeGeneration,
  required int loadGeneration,
  required bool hasActiveChallenge,
});

Future<void> checkCfChallengeFallbackPolicy(FallbackDecider decide) async {
  var checks = 0;
  void expectAction(String actual, String expected, String scenario) {
    if (actual != expected) {
      throw StateError('$scenario: expected $expected, got $actual');
    }
    checks++;
  }

  expectAction(
    decide(probeGeneration: 1, loadGeneration: 1, hasActiveChallenge: false),
    'showNoChallenge',
    'An unchanged page with no challenge still offers retry/exit',
  );
  expectAction(
    decide(probeGeneration: 1, loadGeneration: 1, hasActiveChallenge: true),
    'revealChallenge',
    'An active challenge after the 8-second probe must be visible',
  );
  expectAction(
    decide(probeGeneration: 1, loadGeneration: 2, hasActiveChallenge: false),
    'checkCurrentPage',
    'An old probe cannot label a new loading page no-challenge',
  );
  expectAction(
    decide(probeGeneration: 1, loadGeneration: 2, hasActiveChallenge: true),
    'checkCurrentPage',
    'An old DOM result cannot reveal or cover a different document',
  );

  // The HTTP403/Turnstile trace can navigate again while the DOM read is pending.
  var loadGeneration = 3;
  final pendingDom = Completer<bool>();
  final oldProbe = pendingDom.future.then(
    (hasChallenge) => decide(
      probeGeneration: 3,
      loadGeneration: loadGeneration,
      hasActiveChallenge: hasChallenge,
    ),
  );
  loadGeneration++;
  pendingDom.complete(false);
  expectAction(
    await oldProbe,
    'checkCurrentPage',
    'A navigation during the awaited DOM read invalidates its negative result',
  );
  expectAction(
    decide(
      probeGeneration: loadGeneration,
      loadGeneration: loadGeneration,
      hasActiveChallenge: true,
    ),
    'revealChallenge',
    'The current page check restores the still-active Turnstile challenge',
  );
  print('CF fallback policy: $checks checks passed');
}

Future<void> main() => checkCfChallengeFallbackPolicy(
  ({
    required int probeGeneration,
    required int loadGeneration,
    required bool hasActiveChallenge,
  }) => decideCfChallengeFallback(
    probeGeneration: probeGeneration,
    loadGeneration: loadGeneration,
    hasActiveChallenge: hasActiveChallenge,
  ).name,
);
