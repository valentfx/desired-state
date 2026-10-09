import 'desktop_store.dart';

class DesktopCursorValue {
  const DesktopCursorValue(this.status, {this.value, this.sampleTime});
  final String status;
  final double? value, sampleTime;
}

/// Original range samples only; never interpolate or carry values across outages.
DesktopCursorValue inspectDesktopSignal(
  String name,
  List<SignalPoint> points,
  double cursor,
) {
  if (points.isEmpty) {
    return const DesktopCursorValue('No data');
  }
  if (name == 'Sleep position (recorded estimate)') {
    SignalPoint? state;
    for (final point in points) {
      if (point.$1 <= cursor) {
        state = point;
      }
    }
    return state == null
        ? const DesktopCursorValue('No data')
        : DesktopCursorValue(
            'Recorded estimate',
            value: state.$2,
            sampleTime: state.$1,
          );
  }
  final tolerance =
      name.startsWith('ECG') ||
          name.startsWith('Muse channel') ||
          name.startsWith('H10 ')
      ? .05
      : 1.5;
  SignalPoint? nearest;
  for (final point in points) {
    if (nearest == null ||
        (point.$1 - cursor).abs() <= (nearest.$1 - cursor).abs()) {
      nearest = point;
    }
  }
  if (nearest == null || (nearest.$1 - cursor).abs() > tolerance) {
    return const DesktopCursorValue('No data');
  }
  return nearest.$2.isFinite
      ? DesktopCursorValue(
          'Available',
          value: nearest.$2,
          sampleTime: nearest.$1,
        )
      : DesktopCursorValue('Rejected / unavailable', sampleTime: nearest.$1);
}

List<String> desktopSignalNames(DesktopIndex index) => [
  if (index.overview.containsKey('Sleep position (recorded estimate)'))
    'Sleep position (recorded estimate)',
  if (index.rows.containsKey('measurements')) 'BPM',
  if (index.rows.containsKey('rr')) ...[
    'RR (ms, raw)',
    'RMSSD (ms, recorded screening)',
  ],
  if (index.rows.containsKey('o2ring_measurements')) ...[
    'SpO2 (%)',
    'Ring pulse (bpm)',
    'Ring movement (raw)',
  ],
  if (index.rows.containsKey('muse_bands')) ...[
    for (final band in ['Delta', 'Theta', 'Alpha', 'Beta', 'Gamma'])
      'EEG $band (µV²)',
  ],
  if (index.rows.containsKey('muse_eeg')) ...[
    for (final channel in ['1', '2', '3', '4']) 'Muse channel $channel (µV)',
  ],
  if (index.rows.containsKey('h10_ecg')) 'ECG (µV)',
  if (index.rows.containsKey('h10_accelerometer')) ...[
    'H10 movement (mean sample delta, mG)',
    for (final axis in ['X', 'Y', 'Z']) 'H10 $axis (mG)',
  ],
];
