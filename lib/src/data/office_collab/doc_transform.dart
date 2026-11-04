// Office C' · M2 — local rebase / cherryPick / mapping for `.odoc` steps.
//
// Ports the vendor `Mapping`, `Transform.cherryPick` and the rebase loop the
// Office server performs when a client's `version` is stale:
//
//     mapping = Mapping(remote.posMaps)
//     for each local step: mapped = local.step.map(mapping); if (mapped) apply
//
// All semantics are pinned against `test/fixtures/office_collab/
// transform_vectors.json`, whose `rebase` bucket is produced by the official
// bundle (and cross-checked there against the vendor `Transform.cherryPick`).
//
// Pure Dart, offline, no dependencies.

import 'doc_step.dart';

/// `Transform` — an applied step list over a base document, with the per-step
/// [DocPosMap]s needed for mapping/rebase.
class DocTransform {
  DocTransform(this.baseDoc) : doc = baseDoc;

  final DocJson baseDoc;
  DocJson doc;

  final List<DocStep> steps = <DocStep>[];
  final List<DocJson> _docs = <DocJson>[];
  final List<DocPosMap> _posMaps = <DocPosMap>[];

  int get length => steps.length;

  DocPosMap get lastPosMap => _posMaps.last;

  /// Applies [step], recording it; a failed result is returned (not thrown).
  StepResult maybeStep(DocStep step) {
    final result = step.apply(doc);
    if (result.succ) {
      _docs.add(doc);
      _posMaps.add(step.posMap(doc));
      doc = result.doc!;
    }
    return result;
  }

  /// `Transform.step` — applies [step] and throws on failure.
  DocTransform step(DocStep step) {
    final result = maybeStep(step);
    if (!result.succ) {
      throw DocReplaceError(result.reason ?? 'step failed');
    }
    return this;
  }

  /// `Transform.toMapping()`.
  DocMapping toMapping([int from = 0, int? to]) =>
      DocMapping(_posMaps.sublist(from, to ?? _posMaps.length));

  /// `Transform.cherryPick(steps, posMaps, customMaps, options)` — the vendor
  /// rebase used to re-apply `localSteps` on top of this transform's steps.
  ///
  /// [posMaps] must be the posMaps of [localSteps] against the shared base doc.
  /// [discardBase]/[suppressFailure] mirror the vendor options.
  DocMapping cherryPick(
    List<DocStep> localSteps,
    List<DocPosMap> posMaps, {
    bool discardBase = false,
    bool suppressFailure = false,
  }) {
    // `new Mapping(posMaps.map(invert).reverse(), customMaps.map(invert).reverse())`
    final inverse = <DocPosMap>[
      for (var i = posMaps.length - 1; i >= 0; i--)
        DocPosMap(posMaps[i].ranges, !posMaps[i].inverted),
    ];
    var mapping = DocMapping(inverse).append(toMapping());
    var mapFrom = localSteps.length;
    mapping = mapping.withMapFrom(mapFrom);
    for (var i = 0; i < localSteps.length; i++) {
      final mapped = localSteps[i].map(mapping);
      mapFrom--;
      if (mapped == null) continue;
      final result = maybeStep(mapped);
      if (!result.succ) {
        if (suppressFailure) continue;
        throw DocReplaceError(result.reason ?? 'cherryPick step failed');
      }
      mapping = mapping
          .withPosMaps(<DocPosMap>[...mapping.posMaps, lastPosMap])
          .withMapFrom(mapFrom);
    }
    return mapping;
  }
}

/// The posMaps of [steps] as applied to [baseDoc].
List<DocPosMap> posMapsOf(DocJson baseDoc, List<DocStep> steps) {
  var doc = baseDoc;
  final out = <DocPosMap>[];
  for (final s in steps) {
    out.add(s.posMap(doc));
    final r = s.apply(doc);
    if (r.succ) doc = r.doc!;
  }
  return out;
}

/// Applies [steps] to [doc], throwing on the first failure.
DocJson applySteps(DocJson doc, List<DocStep> steps) {
  var cur = doc;
  for (final s in steps) {
    final r = s.apply(cur);
    if (!r.succ) {
      throw DocReplaceError(r.reason ?? 'step failed');
    }
    cur = r.doc!;
  }
  return cur;
}

/// The result of a concurrent rebase.
class DocRebaseResult {
  const DocRebaseResult({
    required this.doc,
    required this.mappedLocalSteps,
    required this.remoteDoc,
  });

  /// The document after remote steps + the surviving rebased local steps.
  final DocJson doc;

  /// One entry per local step: the mapped step, or null if it was dropped.
  final List<DocStep?> mappedLocalSteps;

  /// The document after the remote steps alone.
  final DocJson remoteDoc;

  /// The local steps that survived the rebase.
  List<DocStep> get surviving =>
      mappedLocalSteps.whereType<DocStep>().toList(growable: false);

  bool get droppedAny => mappedLocalSteps.any((s) => s == null);
}

/// Rebases [localSteps] over [remoteSteps] (both made against [baseDoc]):
/// applies the remote steps, maps every local step through the remote mapping,
/// then applies the mapped steps. Dropped steps are reported, not hidden.
///
/// This is exactly the loop the M0 protocol needs on a `402 Not current
/// version`: refetch, then re-send the rebased steps at the new version.
DocRebaseResult rebaseSteps({
  required DocJson baseDoc,
  required List<DocStep> remoteSteps,
  required List<DocStep> localSteps,
  bool suppressFailure = false,
}) {
  final remoteDoc = applySteps(baseDoc, remoteSteps);
  final mapping = DocMapping(posMapsOf(baseDoc, remoteSteps));
  var doc = remoteDoc;
  final mapped = <DocStep?>[];
  for (final s in localSteps) {
    final m = s.map(mapping);
    mapped.add(m);
    if (m == null) continue;
    final r = m.apply(doc);
    if (!r.succ) {
      if (suppressFailure) continue;
      throw DocReplaceError(r.reason ?? 'rebased step failed');
    }
    doc = r.doc!;
  }
  return DocRebaseResult(
    doc: doc,
    mappedLocalSteps: mapped,
    remoteDoc: remoteDoc,
  );
}

/// Cross-checks `rebaseSteps` against the vendor `Transform.cherryPick`
/// semantics (which the fixture generator verified to agree for every rebase
/// vector). Returns the cherryPick document.
DocJson cherryPickSteps({
  required DocJson baseDoc,
  required List<DocStep> remoteSteps,
  required List<DocStep> localSteps,
  bool suppressFailure = false,
}) {
  final tr = DocTransform(baseDoc);
  for (final s in remoteSteps) {
    tr.step(s);
  }
  tr.cherryPick(
    localSteps,
    posMapsOf(baseDoc, localSteps),
    suppressFailure: suppressFailure,
  );
  return tr.doc;
}
