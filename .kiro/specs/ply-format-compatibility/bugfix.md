# Bugfix Requirements Document

## Introduction

The Gaussian Splat Viewer correctly renders standard 3DGS PLY files (e.g., Room.ply from Hugging Face) but produces incorrect results when loading PLY files exported from Luma.ai and other non-standard sources. Symptoms include flat/washed-out appearance, incorrect camera positioning, and splats being clipped or invisible. The root causes span several layers: opacity values that may already be in [0,1] range receiving a redundant sigmoid transform, scale values that may not be in log-space receiving an unconditional `exp()`, a fixed `farZ` of 2000 that is too small for large outdoor scenes, a `maxScaleThreshold` of 10.0 that clips valid large-scale outdoor splats, and camera auto-positioning logic that does not account for scenes with vastly different spatial extents or coordinate system conventions (Y-up vs Z-up).

## Bug Analysis

### Current Behavior (Defect)

1.1 WHEN a PLY file stores opacity values already in the linear [0,1] range (as Luma.ai exports do) THEN the system applies `sigmoid()` unconditionally, producing incorrect opacity values (e.g., an opacity of 0.9 becomes ~0.71 instead of 0.9, and an opacity of 0.0 becomes 0.5 instead of 0.0), causing all splats to appear semi-transparent and washed out

1.2 WHEN a PLY file stores scale values already in linear (non-log) space THEN the system applies `exp()` unconditionally, producing exponentially inflated scale values that cause splats to appear enormous or be clipped by `maxScaleThreshold`

1.3 WHEN a large outdoor scene is loaded whose spatial extent exceeds the fixed `farZ` of 2000 units THEN the system clips splats beyond that depth, causing large portions of the scene to disappear or render incorrectly

1.4 WHEN a scene contains splats with scale values larger than `maxScaleThreshold` (10.0) THEN the system silently discards or clips those splats, causing valid outdoor splats to be missing from the render

1.5 WHEN a PLY file uses a Z-up coordinate system (as some Luma.ai exports do) instead of the Y-up convention assumed by the renderer THEN the system renders the scene rotated 90° (scene appears on its side or upside-down) and the camera auto-positioning places the camera at an incorrect elevation

1.6 WHEN a large outdoor scene is loaded and camera distance is set to `radius * 2.5` THEN the system positions the camera so far from the scene center that the entire scene appears as a tiny dot, or so close that the camera is inside the scene geometry, because the bounding-sphere radius of an outdoor scene can be orders of magnitude larger than an indoor scene

### Expected Behavior (Correct)

2.1 WHEN a PLY file stores opacity values already in the linear [0,1] range THEN the system SHALL detect this condition (e.g., by inspecting the value distribution or a file-format hint) and skip the `sigmoid()` transform, preserving the original opacity values

2.2 WHEN a PLY file stores scale values already in linear space THEN the system SHALL detect this condition and skip the `exp()` transform, preserving the original scale values

2.3 WHEN a large outdoor scene is loaded whose spatial extent exceeds the current `farZ` THEN the system SHALL dynamically set `farZ` to at least `sceneRadius * 4` (or a suitable multiple) so that all splats within the scene bounds remain visible

2.4 WHEN a scene contains splats with scale values larger than the current `maxScaleThreshold` THEN the system SHALL dynamically raise `maxScaleThreshold` to accommodate the scene's actual scale distribution, preventing valid splats from being discarded

2.5 WHEN a PLY file uses a Z-up coordinate system THEN the system SHALL detect this convention and apply a coordinate-system correction transform so the scene renders upright with the correct orientation

2.6 WHEN any PLY file is loaded THEN the system SHALL compute a camera distance that places the scene comfortably in view regardless of scene scale, using a strategy that accounts for both the scene radius and the current `nearZ`/`farZ` range (e.g., clamping distance so the scene fits within the depth range and is not smaller than a minimum screen fraction)

### Unchanged Behavior (Regression Prevention)

3.1 WHEN a standard 3DGS PLY file (e.g., from Hugging Face) stores opacity in logit space THEN the system SHALL CONTINUE TO apply `sigmoid()` correctly, producing the same opacity values as before

3.2 WHEN a standard 3DGS PLY file stores scale in log space THEN the system SHALL CONTINUE TO apply `exp()` correctly, producing the same scale values as before

3.3 WHEN an indoor scene with a spatial extent well within 2000 units is loaded THEN the system SHALL CONTINUE TO set `farZ` to a value that renders the scene correctly without visual artifacts

3.4 WHEN a standard scene with splat scales within the existing threshold is loaded THEN the system SHALL CONTINUE TO render all splats without any change in appearance

3.5 WHEN a standard 3DGS PLY file using Y-up coordinates is loaded THEN the system SHALL CONTINUE TO render the scene with the correct upright orientation without applying any coordinate correction

3.6 WHEN an indoor scene is loaded THEN the system SHALL CONTINUE TO position the camera at a comfortable viewing distance that shows the full scene, consistent with current behavior for standard files

---

## Bug Condition Pseudocode

### Bug Condition Functions

```pascal
FUNCTION isLinearOpacityFile(splats)
  INPUT: splats — array of parsed GaussianSplat with raw opacity values
  OUTPUT: boolean

  // Heuristic: if the majority of raw opacity values are already in (0,1)
  // and none are strongly negative (logit-space values for low opacity are
  // large negative numbers, e.g. -5 to -10), the file likely stores linear opacity
  sampleCount ← min(1000, splats.count)
  outOfLogitRange ← COUNT of splats[0..sampleCount] WHERE abs(rawOpacity) < 5.0
                    AND rawOpacity > 0.0 AND rawOpacity < 1.0
  RETURN (outOfLogitRange / sampleCount) > 0.8
END FUNCTION

FUNCTION isLinearScaleFile(splats)
  INPUT: splats — array of parsed GaussianSplat with raw scale values
  OUTPUT: boolean

  // Heuristic: standard 3DGS stores log-scale, so raw values are typically
  // in [-10, 2]. If the majority of raw scale values are positive and > 2,
  // the file likely stores linear scale already.
  sampleCount ← min(1000, splats.count)
  likelyLinear ← COUNT of splats[0..sampleCount] WHERE scale_0 > 0.0 AND scale_0 < 10.0
                 AND scale_0 is NOT in typical log range [-10, 2]
  RETURN (likelyLinear / sampleCount) > 0.8
END FUNCTION

FUNCTION isZUpCoordinateSystem(splats)
  INPUT: splats — array of parsed GaussianSplat positions
  OUTPUT: boolean

  // Heuristic: in a Z-up scene the variance of Z positions is comparable to
  // X/Y variance and the centroid Z is significantly non-zero relative to extent.
  // Alternatively, detect via PLY file comment/metadata if present.
  yVariance ← variance of splats[*].position.y
  zVariance ← variance of splats[*].position.z
  RETURN zVariance > yVariance * 2.0
END FUNCTION
```

### Fix-Checking Properties

```pascal
// Property 1.1: Opacity — Fix Checking
FOR ALL splats WHERE isLinearOpacityFile(splats) DO
  result ← loadedSplat'.opacity
  ASSERT result ≈ rawOpacity  // no sigmoid applied
  ASSERT result IN [0.0, 1.0]
END FOR

// Property 1.2: Scale — Fix Checking
FOR ALL splats WHERE isLinearScaleFile(splats) DO
  result ← loadedSplat'.scale
  ASSERT result ≈ rawScale  // no exp() applied
END FOR

// Property 1.3: farZ — Fix Checking
FOR ALL scenes WHERE scene.radius * 4 > camera.farZ DO
  ASSERT camera'.farZ >= scene.radius * 4
END FOR

// Property 1.4: maxScaleThreshold — Fix Checking
FOR ALL scenes WHERE max(splat.scale) > splatSettings.maxScaleThreshold DO
  ASSERT splatSettings'.maxScaleThreshold >= max(splat.scale)
END FOR

// Property 1.5: Coordinate system — Fix Checking
FOR ALL splats WHERE isZUpCoordinateSystem(splats) DO
  ASSERT correctionTransform is applied such that scene renders Y-up
END FOR

// Property 1.6: Camera distance — Fix Checking
FOR ALL scenes DO
  d ← camera'.distance
  ASSERT d > camera.nearZ * 2
  ASSERT d < camera.farZ / 2
  ASSERT scene is visible (not a dot, not camera inside geometry)
END FOR
```

### Preservation Properties

```pascal
// Preservation Checking — standard 3DGS files must be unaffected
FOR ALL splats WHERE NOT isLinearOpacityFile(splats) DO
  ASSERT loadedSplat'(rawOpacity) = sigmoid(rawOpacity)  // F = F'
END FOR

FOR ALL splats WHERE NOT isLinearScaleFile(splats) DO
  ASSERT loadedSplat'(rawScale) = exp(rawScale)  // F = F'
END FOR

FOR ALL scenes WHERE NOT isZUpCoordinateSystem(splats) DO
  ASSERT no coordinate correction transform is applied  // F = F'
END FOR
```
