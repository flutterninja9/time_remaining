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
      if (i < 7) {
        last7 += minutes;
      }
      last30 += minutes;
    }

    // Compute streak: consecutive days (up to 30) meeting target
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
        if (i == 0) {
          // If today doesn't meet the target, streak is 0.
          streak = 0;
        }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stats'),
        backgroundColor: const Color(0xFF0F111A),
      ),
      backgroundColor: const Color(0xFF0F111A),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildSummaryCard(title: 'Today', minutes: _todayMinutes),
                      _buildSummaryCard(
                        title: 'Last 7 days',
                        minutes: _last7DaysMinutes,
                      ),
                      _buildSummaryCard(
                        title: 'Last 30 days',
                        minutes: _last30DaysMinutes,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _buildStreakCard(),
                  const SizedBox(height: 24),
                  _buildBarChart(),
                  const SizedBox(height: 24),
                  _buildCheckInTimes(),
                ],
              ),
            ),
    );
  }

  Widget _buildSummaryCard({required String title, required int minutes}) {
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    final text = '${hours}h ${mins}m';
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              text,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStreakCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Streak',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$_streakDays days',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const Icon(Icons.local_fire_department, color: Colors.orangeAccent),
        ],
      ),
    );
  }

  Widget _buildBarChart() {
    final now = DateTime.now();
    final last7Keys = <String>[];
    for (int i = 6; i >= 0; i--) {
      last7Keys.add(_formatStatsDateKey(now.subtract(Duration(days: i))));
    }

    final values = last7Keys.map((k) => _dailyTotals[k] ?? 0).toList();
    final maxMinutes = (values.fold<int>(
      0,
      (a, b) => a > b ? a : b,
    ))
        .clamp(0, 12 * 60);
    final safeMax = maxMinutes == 0 ? 60 : maxMinutes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Last 7 days',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 160,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (int i = 0; i < last7Keys.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              width: 16,
                              height: 120 * (values[i] / safeMax),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                gradient: const LinearGradient(
                                  begin: Alignment.bottomCenter,
                                  end: Alignment.topCenter,
                                  colors: [
                                    Color(0xFF00E5FF),
                                    Color(0xFF00B0FF),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _dayLabelFromKey(last7Keys[i]),
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCheckInTimes() {
    final now = DateTime.now();
    final last7 = <String>[];
    for (int i = 6; i >= 0; i--) {
      last7.add(_formatStatsDateKey(now.subtract(Duration(days: i))));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'First check-in time (last 7 days)',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Column(
          children: [
            for (final key in last7)
              _buildCheckInRow(
                dateLabel: _dayLabelFromKey(key),
                millis: _dailyFirstCheckin[key],
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildCheckInRow({required String dateLabel, int? millis}) {
    String value;
    if (millis == null) {
      value = '--';
    } else {
      final date = DateTime.fromMillisecondsSinceEpoch(millis);
      final hour = date.hour;
      final minute = date.minute;
      final period = hour >= 12 ? 'PM' : 'AM';
      final displayHour = hour > 12 ? hour - 12 : (hour == 0 ? 12 : hour);
      value =
          '${displayHour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} $period';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(dateLabel, style: const TextStyle(color: Colors.white70)),
          Text(value, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  String _dayLabelFromKey(String key) {
    // key is yyyy-MM-dd
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

