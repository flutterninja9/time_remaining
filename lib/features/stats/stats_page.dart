import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  Map<String, int> _dailyTotals = <String, int>{};
  Map<String, int> _dailyFirstCheckin = <String, int>{};

  int _todayMinutes = 0;
  int _last7DaysMinutes = 0;
  int _last30DaysMinutes = 0;
  int _streakDays = 0;

  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final prefs = await SharedPreferences.getInstance();

    final totalsJson = prefs.getString('daily_totals');
    final checkinsJson = prefs.getString('daily_first_checkin');

    Map<String, dynamic> totalsDecoded =
        totalsJson != null && totalsJson.isNotEmpty
            ? jsonDecode(totalsJson) as Map<String, dynamic>
            : <String, dynamic>{};

    Map<String, dynamic> checkinsDecoded =
        checkinsJson != null && checkinsJson.isNotEmpty
            ? jsonDecode(checkinsJson) as Map<String, dynamic>
            : <String, dynamic>{};

    final dailyTotals = <String, int>{};
    for (final entry in totalsDecoded.entries) {
      final value = entry.value;
      if (value is int) {
        dailyTotals[entry.key] = value;
      } else if (value is num) {
        dailyTotals[entry.key] = value.toInt();
      }
    }

    final dailyFirstCheckin = <String, int>{};
    for (final entry in checkinsDecoded.entries) {
      final value = entry.value;
      if (value is int) {
        dailyFirstCheckin[entry.key] = value;
      } else if (value is num) {
        dailyFirstCheckin[entry.key] = value.toInt();
      }
    }

    final now = DateTime.now();
    final todayKey = _formatStatsDateKey(now);

    int todayMinutes = dailyTotals[todayKey] ?? 0;
    int last7 = 0;
    int last30 = 0;

    for (int i = 0; i < 30; i++) {
      final day = now.subtract(Duration(days: i));
      final key = _formatStatsDateKey(day);
      final minutes = dailyTotals[key] ?? 0;
      if (i < 7) last7 += minutes;
      last30 += minutes;
    }

    final targetHours =
        int.tryParse(prefs.getString('target_hours') ?? '8') ?? 8;
    final targetMinutes =
        targetHours * 60 +
        (int.tryParse(prefs.getString('target_minutes') ?? '0') ?? 0);

    int streak = 0;
    for (int i = 0; i < 30; i++) {
      final day = now.subtract(Duration(days: i));
      final key = _formatStatsDateKey(day);
      final minutes = dailyTotals[key] ?? 0;
      if (minutes >= targetMinutes && targetMinutes > 0) {
        streak += 1;
      } else {
        if (i == 0) streak = 0;
        break;
      }
    }

    setState(() {
      _dailyTotals = dailyTotals;
      _dailyFirstCheckin = dailyFirstCheckin;
      _todayMinutes = todayMinutes;
      _last7DaysMinutes = last7;
      _last30DaysMinutes = last30;
      _streakDays = streak;
      _isLoading = false;
    });
  }

  String _formatMinutes(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return '${h}h ${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Stats',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 36),

                  // ── Overview ─────────────────────────────────────────
                  _sectionHeader(context, Icons.bar_chart_outlined, 'OVERVIEW'),
                  const SizedBox(height: 16),
                  _statRow(context, 'Today', _formatMinutes(_todayMinutes)),
                  _divider(context),
                  _statRow(context, 'Last 7 days', _formatMinutes(_last7DaysMinutes)),
                  _divider(context),
                  _statRow(context, 'Last 30 days', _formatMinutes(_last30DaysMinutes)),
                  _divider(context),
                  _statRow(context, 'Streak', '$_streakDays days'),

                  const SizedBox(height: 36),

                  // ── Bar chart ────────────────────────────────────────
                  _sectionHeader(context, Icons.calendar_today_outlined, 'LAST 7 DAYS'),
                  const SizedBox(height: 16),
                  _buildBarChart(context),

                  const SizedBox(height: 36),

                  // ── Check-in times ───────────────────────────────────
                  _sectionHeader(context, Icons.access_time_outlined, 'CHECK-IN TIMES'),
                  const SizedBox(height: 16),
                  _buildCheckInTimes(context),
                ],
              ),
            ),
    );
  }

  // ── UI Helpers ───────────────────────────────────────────────────────────

  Widget _sectionHeader(BuildContext context, IconData icon, String label) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      children: [
        Icon(icon, size: 14, color: cs.primary),
        const SizedBox(width: 8),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: cs.primary,
            letterSpacing: 2.0,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _divider(BuildContext context) {
    return Divider(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
      thickness: 1,
      height: 1,
    );
  }

  Widget _statRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.85),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBarChart(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final now = DateTime.now();
    final last7Keys = <String>[];
    for (int i = 6; i >= 0; i--) {
      last7Keys.add(_formatStatsDateKey(now.subtract(Duration(days: i))));
    }

    final values = last7Keys.map((k) => _dailyTotals[k] ?? 0).toList();
    final maxMinutes = values.fold<int>(0, (a, b) => a > b ? a : b).clamp(0, 12 * 60);
    final safeMax = maxMinutes == 0 ? 60 : maxMinutes;

    return SizedBox(
      height: 120,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (int i = 0; i < last7Keys.length; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Container(
                          width: 4,
                          height: (80.0 * (values[i] / safeMax)).clamp(0.0, 80.0),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2),
                            color: cs.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _dayLabelFromKey(last7Keys[i]),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.4),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCheckInTimes(BuildContext context) {
    final now = DateTime.now();
    final last7 = <String>[];
    for (int i = 6; i >= 0; i--) {
      last7.add(_formatStatsDateKey(now.subtract(Duration(days: i))));
    }

    return Column(
      children: [
        for (int i = 0; i < last7.length; i++) ...[
          _checkInRow(
            context,
            dateLabel: _dayLabelFromKey(last7[i]),
            millis: _dailyFirstCheckin[last7[i]],
          ),
          if (i < last7.length - 1) _divider(context),
        ],
      ],
    );
  }

  Widget _checkInRow(
    BuildContext context, {
    required String dateLabel,
    int? millis,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    String value;
    if (millis == null) {
      value = '--';
    } else {
      final date = DateTime.fromMillisecondsSinceEpoch(millis);
      final hour = date.hour;
      final minute = date.minute;
      final period = hour >= 12 ? 'PM' : 'AM';
      final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
      value = '${displayHour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} $period';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              dateLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }

  // ── Data Helpers ─────────────────────────────────────────────────────────

  String _dayLabelFromKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return key;
    final year = int.tryParse(parts[0]) ?? DateTime.now().year;
    final month = int.tryParse(parts[1]) ?? DateTime.now().month;
    final day = int.tryParse(parts[2]) ?? DateTime.now().day;
    final date = DateTime(year, month, day);
    const labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return labels[date.weekday - 1];
  }

  String _formatStatsDateKey(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }
}
