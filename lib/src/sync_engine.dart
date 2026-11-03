import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'domain/marzullo_engine.dart';
import 'domain/time_sample.dart';
import 'domain/time_source.dart';
import 'domain/time_interval.dart';
import 'exceptions.dart';
import 'models.dart';
import 'monotonic_clock.dart';
import 'source_quality_tracker.dart';
import 'sources/time_sources.dart';
import 'infra/sync_observer.dart';
import 'infra/consensus_cache.dart';

/// ## Absolute Top Tier: Distributed Lifecycle Orchestration
///
/// The [SyncEngine] is the heart of the time integrity subsystem. It implements
/// a self-healing operational state machine designed for adversarial robustness.
///
/// Key Refinements:
/// 1. **Racing Parallelism**: Minimizes cold-start latency through concurrent
///    multi-source querying.
/// 2. **Adaptive Stability Escalation**: Dynamically adjusts quorum requirements
///    based on population variance.
/// 3. **Mathematical Outlier Filtering**: Uses median-based guards to neutralize
///    malicious or jittery time authorities.
final class SyncEngine {
  /// Documented.
  SyncEngine({
    required TrustedTimeConfig config,
    required MonotonicClock clock,
    SyncObserver? observer,
    ConsensusCache? cache,
  }) : _config = config,
       _clock = clock,
       _observer = observer,
       _cache = cache,
       _engine = MarzulloEngine(
         minQuorumRatio: config.minQuorumRatio,
         maxAllowedUncertaintyMs: config.maxAllowedUncertaintyMs,
         minGroupCount: config.minGroupCount,
       );

  final TrustedTimeConfig _config;
  final MonotonicClock _clock;
  final SyncObserver? _observer;
  final ConsensusCache? _cache;
  final MarzulloEngine _engine;

  /// Lazily-initialized list of authoritative time sources.
  late final List<TimeSource> _sources = [
    for (final host in _config.ntpServers) NtpSource(host),
    for (final url in _config.httpsSources) HttpsSource(url),
    for (final host in _config.ntsServers)
      NtsSource(
        host,
        port: _config.ntsPort,
        trustMode: _config.ntsTrustMode,
        customRoots: _config.ntsCustomRoots,
        timeoutMs: _config.ntsTimeoutMs,
        clock: _clock,
        oscillatorDriftFactor: _config.oscillatorDriftFactor,
        onStratumObserved: (s) =>
            _qualityTracker.setStratum('${TimeSource.prefixNts}$host', s),
      ),
    ..._config.additionalSources,
  ];

  /// Tracks consecutive failures for each source to implement exponential cooldown.
  final _sourceHealth = <String, int>{};

  /// Precise timestamps until which a source is considered "blacklisted."
  final _blacklistUntil = <String, DateTime>{};

  final _qualityTracker = SourceQualityTracker();

  int _syncAttempts = 0;
  int _syncCycle = 0;

  bool get _diagnosticsEnabled => kDebugMode && _config.enableDiagnostics;

  void _log(int cycle, String message) {
    if (_diagnosticsEnabled) {
      debugPrint('[TrustedTime][sync=$cycle] $message');
    }
  }

  void _logPopulation(
    int cycle,
    List<TimeSample> samples,
    Map<String, int> receivedAtMs,
  ) {
    if (!_diagnosticsEnabled) return;
    final valid = samples
        .where(
          (sample) =>
              sample.uncertaintyMs >= 0 &&
              sample.uncertaintyMs <= _config.maxAllowedUncertaintyMs,
        )
        .toList();
    final required = (valid.length * _config.minQuorumRatio).ceil();
    _log(
      cycle,
      'population retained=${samples.length} engineEligible=${valid.length} '
      'requiredOverlap=$required minimumQuorum=${_config.minimumQuorum} '
      'uniqueSources=${valid.map((sample) => sample.sourceId).toSet().length} '
      'groups=${valid.map((sample) => sample.groupId).toSet().join(',')} '
      'minGroupCount=${_config.minGroupCount} (confidence grading only)',
    );
    for (final sample in samples) {
      _log(
        cycle,
        'retained source=${sample.sourceId} group=${sample.groupId} '
        'utcMs=${sample.interval.midpoint} interval=${sample.interval} '
        'uncertaintyMs=${sample.uncertaintyMs} '
        'engineEligible=${valid.contains(sample)} '
        'receivedAtSyncMs=${receivedAtMs[sample.sourceId]} '
        'auth=${sample.authLevel.name}',
      );
    }
    for (var firstIndex = 0; firstIndex < samples.length; firstIndex++) {
      for (
        var secondIndex = firstIndex + 1;
        secondIndex < samples.length;
        secondIndex++
      ) {
        final first = samples[firstIndex];
        final second = samples[secondIndex];
        final rawGap = max(
          0,
          max(first.interval.startMs, second.interval.startMs) -
              min(first.interval.endMs, second.interval.endMs),
        );
        final midpointDelta =
            second.interval.midpoint - first.interval.midpoint;
        final receiptDelta =
            receivedAtMs[second.sourceId]! - receivedAtMs[first.sourceId]!;
        _log(
          cycle,
          'pair first=${first.sourceId} second=${second.sourceId} '
          'alignedOverlap=${first.interval.startMs <= second.interval.endMs && second.interval.startMs <= first.interval.endMs} '
          'alignedGapMs=$rawGap alignedMidpointDeltaMs=$midpointDelta '
          'receiptDeltaMs=$receiptDelta '
          'basisUptimeMs=${first.uptimeMs}',
        );
      }
    }
  }

  /// Executes a full synchronization cycle across all healthy sources.
  ///
  /// This method is the primary driver of trust establishment. It races sources,
  /// performs adaptive outlier filtering, and requires stability across
  /// multiple samples before finalizing an anchor.
  Future<TrustAnchor> sync() async {
    final cycle = ++_syncCycle;
    _observer?.onSyncStarted();
    final swSync = Stopwatch()..start();

    final samples = <TimeSample>[];
    final receivedAtMs = <String, int>{};
    final completer = Completer<TrustAnchor>();
    var streamClosed = false;
    StreamSubscription<TimeSample?>? streamSub;
    final sampleController = StreamController<TimeSample?>();

    try {
      final referenceUptimeMs = await _clock.uptimeMs();
      if (referenceUptimeMs < 0) {
        throw TrustedTimeSyncException('Negative synchronization uptime.');
      }
      final now = DateTime.now();
      _log(
        cycle,
        'start configured=${_sources.length} '
        'maxLatencyMs=${_config.maxLatency.inMilliseconds} '
        'ntsTimeoutMs=${_config.ntsTimeoutMs} '
        'minQuorumRatio=${_config.minQuorumRatio} '
        'minimumQuorum=${_config.minimumQuorum} '
        'maxAllowedUncertaintyMs=${_config.maxAllowedUncertaintyMs} '
        'earlyExit=${_config.earlyExit}',
      );
      _log(cycle, 'referenceUptimeMs=$referenceUptimeMs');

      // Quality-ranked source ordering with starvation guard.
      // Sources that haven't been queried within _kStarvationCycles are always
      // included so their quality estimates remain fresh.
      final healthySources = _sources.where((s) {
        final until = _blacklistUntil[s.id];
        final healthy = until == null || now.isAfter(until);
        if (!healthy) {
          _log(
            cycle,
            'skip source=${s.id} reason=cooldown '
            'remainingMs=${until.difference(now).inMilliseconds}',
          );
        }
        return healthy;
      }).toList();

      final rankedIds = _qualityTracker.ranked(healthySources.map((s) => s.id));
      final activeSources = [
        // High-quality sources first, in ranked order.
        for (final id in rankedIds)
          healthySources.firstWhere((s) => s.id == id),
        // Starvation-forced sources not already in the ranked set.
        for (final s in healthySources)
          if (_qualityTracker.isStarved(s.id) && !rankedIds.contains(s.id)) s,
      ];

      var pendingQueries = activeSources.length;
      _log(
        cycle,
        'active=${activeSources.map((source) => source.id).join(',')}',
      );
      if (pendingQueries == 0) {
        throw TrustedTimeSyncException(
          'All available time sources are currently in exponential cooldown due to persistent failures.',
        );
      }

      TimeInterval? lastStabilityInterval;
      var stableCount = 0;
      var rejectedInvalid = 0;

      // 1. Process samples sequentially via a stream to preserve determinism
      // and prevent race conditions during list mutation. This ensures that
      // outlier filtering and consensus resolution always happen on a consistent
      // snapshot of the sample population.
      streamSub = sampleController.stream.listen((sample) {
        if (completer.isCompleted) return;

        if (sample != null) {
          receivedAtMs[sample.sourceId] = swSync.elapsedMilliseconds;
          _log(
            cycle,
            'sample source=${sample.sourceId} '
            'receivedAtSyncMs=${swSync.elapsedMilliseconds} '
            'utcMs=${sample.interval.midpoint} interval=${sample.interval} '
            'uncertaintyMs=${sample.uncertaintyMs} '
            'group=${sample.groupId} auth=${sample.authLevel.name}',
          );
          // Filter samples with negative uncertainty early, before both Marzullo
          // and the anchor reduce. Negative uncertainty indicates clock errors.
          if (sample.uncertaintyMs < 0) {
            _log(
              cycle,
              'reject source=${sample.sourceId} reason=negative-uncertainty',
            );
            rejectedInvalid++;
            _observer?.onSourceFailed(
              sample.sourceId,
              'Sample rejected: negative uncertainty (RTT)',
            );
            pendingQueries--;
            if (pendingQueries == 0 && !completer.isCompleted) {
              _finalizeSync(
                samples,
                rejectedInvalid,
                activeSources.length,
                completer,
                referenceUptimeMs,
              );
            }
            return;
          }

          samples.add(sample);
          _observer?.onSampleReceived(sample);

          // Adaptive Outlier Filtering: Uses a median-based guard to identify
          // and exclude sources that deviate significantly from the population.
          if (samples.length >= 3) {
            final uncertainties = samples.map((s) => s.uncertaintyMs).toList()
              ..sort();
            final medianU = uncertainties[uncertainties.length ~/ 2];

            // Heuristic: If a sample's uncertainty is > 3x the median, it is
            // likely malicious or experiencing extreme network jitter.
            if (sample.uncertaintyMs > max(medianU * 3, 500)) {
              samples.remove(sample);
              _log(
                cycle,
                'exclude source=${sample.sourceId} reason=adaptive-outlier '
                'uncertaintyMs=${sample.uncertaintyMs} medianUncertaintyMs=$medianU',
              );
              _observer?.onSourceFailed(
                sample.sourceId,
                'Adaptive exclusion: statistical outlier detected',
              );
            }
          }

          final result = _engine.resolve(samples);
          _log(
            cycle,
            result == null
                ? 'resolve retained=${samples.length} result=no-consensus'
                : 'resolve retained=${samples.length} '
                      'participants=${result.participants.map((sample) => sample.sourceId).join(',')} '
                      'interval=${result.interval} uncertaintyMs=${result.uncertaintyMs} '
                      'confidence=${result.confidence.name}',
          );
          if (result != null &&
              result.participantCount >= _config.minimumQuorum) {
            // Stability Check: Escalates quorum requirements if high variance
            // is detected, ensuring we don't anchor to a jittery consensus.
            final varianceDetected = samples.any(
              (s) =>
                  (s.interval.midpoint - result.utc.millisecondsSinceEpoch)
                      .abs() >
                  500,
            );
            final requiredStability = varianceDetected ? 3 : 2;

            if (lastStabilityInterval == result.interval) {
              stableCount++;
            } else {
              stableCount = 1;
            }
            lastStabilityInterval = result.interval;

            if (stableCount >= requiredStability) {
              // Early Exit: If configured, we return as soon as a stable quorum
              // is reached to minimize power and network consumption.
              if (_config.earlyExit || samples.length == activeSources.length) {
                swSync.stop();
                unawaited(
                  _completeSync(
                    result,
                    swSync.elapsedMilliseconds,
                    completer,
                    referenceUptimeMs,
                  ),
                );
              }
            }
          }
        }

        pendingQueries--;
        if (pendingQueries == 0 && !completer.isCompleted) {
          _finalizeSync(
            samples,
            rejectedInvalid,
            activeSources.length,
            completer,
            referenceUptimeMs,
            elapsedMs: swSync.elapsedMilliseconds,
          );
        }
      });

      // 2. Launch racing queries
      for (final source in activeSources) {
        unawaited(
          _querySafe(source, cycle, swSync, referenceUptimeMs)
              .then((s) {
                if (!streamClosed && !sampleController.isClosed) {
                  sampleController.add(s);
                }
              })
              .catchError((Object e) {
                _log(
                  cycle,
                  'query callback failed source=${source.id} error=$e',
                );
                _observer?.onSourceFailed(source.id, e);
                if (!streamClosed && !sampleController.isClosed) {
                  sampleController.add(
                    null,
                  ); // Ensure pendingQueries still decrements
                }
              }),
        );
      }

      final anchor = await completer.future.timeout(
        _config.maxLatency + const Duration(seconds: 1),
        onTimeout: () {
          if (!completer.isCompleted &&
              samples.length >= _config.minimumQuorum) {
            final result = _engine.resolve(samples);
            if (result != null &&
                result.participantCount >= _config.minimumQuorum) {
              return _createAnchor(result, referenceUptimeMs);
            }
          }
          throw TrustedTimeSyncException(
            'Synchronization timed out before reaching a stable quorum.',
          );
        },
      );

      _syncAttempts = 0;
      _cache?.update(anchor);
      _qualityTracker.advanceCycle();
      _log(
        cycle,
        'success elapsedMs=${swSync.elapsedMilliseconds} '
        'utc=${DateTime.fromMillisecondsSinceEpoch(anchor.networkUtcMs, isUtc: true).toIso8601String()} '
        'uncertaintyMs=${anchor.uncertaintyMs} auth=${anchor.authLevel.name}',
      );
      return anchor;
    } catch (e) {
      _logPopulation(cycle, samples, receivedAtMs);
      _log(cycle, 'failed elapsedMs=${swSync.elapsedMilliseconds} error=$e');
      _observer?.onSyncFailed(e);
      _syncAttempts++;
      rethrow;
    } finally {
      streamClosed = true;
      // Cancel subscription first to prevent hanging when controller closes
      await (streamSub ?? sampleController.stream.listen(null)).cancel();
      await sampleController.close();
    }
  }

  Future<void> _completeSync(
    ConsensusResult result,
    int latencyMs,
    Completer<TrustAnchor> completer,
    int referenceUptimeMs,
  ) async {
    if (completer.isCompleted) return;

    try {
      final anchor = await _createAnchor(result, referenceUptimeMs);
      _observer?.onConsensusReached(result);

      // Record quality observations for all participant samples.
      final participantIds = result.participants.map((s) => s.sourceId).toSet();
      for (final sample in result.participants) {
        _qualityTracker.record(
          sourceId: sample.sourceId,
          uncertaintyMs: sample.uncertaintyMs,
          participatedInConsensus: participantIds.contains(sample.sourceId),
        );
      }

      _observer?.onMetricsReported(
        SyncMetrics(
          latencyMs: latencyMs,
          uncertaintyMs: result.uncertaintyMs,
          participantCount: result.participantCount,
          groupCount: result.groupCount,
          confidence: result.confidence,
          confidenceBreakdown: {
            'depth': result.participantCount / _sources.length,
            'diversity': result.groupCount / 2.0,
            'stability': 1.0,
          },
        ),
      );

      if (!completer.isCompleted) completer.complete(anchor);
    } catch (e) {
      if (!completer.isCompleted) completer.completeError(e);
    }
  }

  Future<TrustAnchor> _createAnchor(
    ConsensusResult result,
    int referenceUptimeMs,
  ) async {
    // Anchor selection validates that consensus has participant samples.
    // This prevents outliers from corrupting the monotonic clock reference.
    final participantSamples = result.participants;
    if (participantSamples.isEmpty) {
      throw TrustedTimeSyncException(
        'Consensus result has no participant samples',
      );
    }

    final clock = _clock;
    final bootId = clock is BootIdentityClock ? await clock.bootId() : null;
    final uptimeMs = await _clock.uptimeMs();
    final elapsedMs = uptimeMs - referenceUptimeMs;
    if (elapsedMs < 0) {
      throw TrustedTimeSyncException('Monotonic clock regressed during sync.');
    }
    final wallMs = DateTime.now().millisecondsSinceEpoch;

    return TrustAnchor(
      networkUtcMs: result.utc.millisecondsSinceEpoch + elapsedMs,
      uptimeMs: uptimeMs,
      bootId: bootId,
      wallMs: wallMs,
      uncertaintyMs:
          result.uncertaintyMs +
          (elapsedMs * _config.oscillatorDriftFactor).ceil(),
      authLevel: result.authLevel,
      confidence: result.confidence,
    );
  }

  /// Finalizes synchronization when all queries complete.
  void _finalizeSync(
    List<TimeSample> samples,
    int rejectedInvalid,
    int totalSources,
    Completer<TrustAnchor> completer,
    int referenceUptimeMs, {
    int? elapsedMs,
  }) {
    if (completer.isCompleted) return;

    // All sources responded but we haven't reached stability.
    // Try one final resolve with all samples before failing.
    final finalResult = _engine.resolve(samples);
    if (finalResult != null &&
        finalResult.participantCount >= _config.minimumQuorum) {
      unawaited(
        _completeSync(
          finalResult,
          elapsedMs ?? 0,
          completer,
          referenceUptimeMs,
        ),
      );
    } else {
      // Improved quorum-failure messaging with accurate counts
      final eligibleCount = samples.length;
      final sampleWord = eligibleCount == 1 ? 'sample' : 'samples';
      final rejectedWord = rejectedInvalid == 1 ? 'source was' : 'sources were';

      completer.completeError(
        TrustedTimeSyncException(
          'Failed to reach quorum: got $eligibleCount eligible $sampleWord '
          '($rejectedInvalid $rejectedWord rejected as invalid) from $totalSources total sources.',
        ),
      );
    }
  }

  /// Wraps a source query with timeout and health-tracking logic.
  Future<TimeSample?> _querySafe(
    TimeSource source,
    int cycle,
    Stopwatch syncClock,
    int referenceUptimeMs,
  ) async {
    final queryClock = Stopwatch()..start();
    _log(cycle, 'query start source=${source.id}');
    try {
      final sample = await source.getTime().timeout(_config.maxLatency);
      if (sample.interval.startMs > sample.interval.endMs) {
        throw TrustedTimeSyncException('Sample has an inverted UTC interval.');
      }
      final observedUptimeMs = sample.uptimeMs ?? await _clock.uptimeMs();
      if (observedUptimeMs < referenceUptimeMs) {
        throw TrustedTimeSyncException(
          'Sample uptime precedes sync reference.',
        );
      }
      final shiftMs = observedUptimeMs - referenceUptimeMs;
      final projectionErrorMs =
          1 + (shiftMs * _config.oscillatorDriftFactor).ceil();
      final aligned = TimeSample(
        interval: TimeInterval(
          startMs: sample.interval.startMs - shiftMs - projectionErrorMs,
          endMs: sample.interval.endMs - shiftMs + projectionErrorMs,
        ),
        sourceId: sample.sourceId,
        groupId: sample.groupId,
        authLevel: sample.authLevel,
        uptimeMs: referenceUptimeMs,
      );
      _log(
        cycle,
        'query success source=${source.id} '
        'queryElapsedMs=${queryClock.elapsedMilliseconds} '
        'receivedAtSyncMs=${syncClock.elapsedMilliseconds} '
        'rawInterval=${sample.interval} observedUptimeMs=$observedUptimeMs '
        'shiftMs=$shiftMs alignedInterval=${aligned.interval}',
      );
      _sourceHealth[source.id] = 0; // Reset failure count on success
      _blacklistUntil.remove(source.id);
      return aligned;
    } catch (e) {
      _observer?.onSourceFailed(source.id, e);
      _qualityTracker.recordFailure(source.id);

      final score = (_sourceHealth[source.id] ?? 0) + 1;
      _sourceHealth[source.id] = score;
      final cooldownMin = pow(2, min(score, 6)).toInt();
      _blacklistUntil[source.id] = DateTime.now().add(
        Duration(minutes: cooldownMin),
      );
      _log(
        cycle,
        'query failed source=${source.id} '
        'queryElapsedMs=${queryClock.elapsedMilliseconds} '
        'errorType=${e.runtimeType} error=$e cooldownMinutes=$cooldownMin',
      );

      return null;
    }
  }

  /// Calculates the next retry delay for the entire engine.
  Duration getNextRetryDelay() {
    if (_syncAttempts == 0) return Duration.zero;
    final exponent = min(_syncAttempts, 8);
    final seconds = pow(2, exponent).toInt();
    return Duration(seconds: seconds);
  }

  /// Releases network and platform resources.
  void dispose() {
    for (final source in _sources) {
      if (source is HttpsSource) source.dispose();
      if (source is NtsSource) source.dispose();
    }
  }
}
