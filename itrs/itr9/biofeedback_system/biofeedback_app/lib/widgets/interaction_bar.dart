// lib/widgets/hrv_chart.dart

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../constants.dart';

class HRVChart extends StatelessWidget {
  final List<double> hrvData;
  final List<double> hrData;

  const HRVChart({
    super.key,
    required this.hrvData,
    required this.hrData,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height:  120,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        const Color(AppConstants.surfaceColor),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(AppConstants.cardBorder),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'HRV TREND',
            style: TextStyle(
              color:         const Color(AppConstants.textSecondary),
              fontSize:      10,
              letterSpacing: 1.2,
              fontWeight:    FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: hrvData.length < 2
                ? Center(
                    child: Text(
                      'Collecting data...',
                      style: TextStyle(
                        color:    const Color(
                            AppConstants.textSecondary),
                        fontSize: 12,
                      ),
                    ),
                  )
                : LineChart(
                    LineChartData(
                      lineBarsData: [
                        LineChartBarData(
                          spots: hrvData
                              .asMap()
                              .entries
                              .map((e) => FlSpot(
                                    e.key.toDouble(),
                                    e.value,
                                  ))
                              .toList(),
                          isCurved:     true,
                          color:        const Color(
                              AppConstants.calmColor),
                          barWidth:     2,
                          dotData:      const FlDotData(
                              show: false),
                          belowBarData: BarAreaData(
                            show:  true,
                            color: const Color(
                                    AppConstants.calmColor)
                                .withOpacity(0.1),
                          ),
                        ),
                      ],
                      gridData:   const FlGridData(show: false),
                      borderData: FlBorderData(show: false),
                      titlesData: const FlTitlesData(
                          show: false),
                      lineTouchData: const LineTouchData(
                          enabled: false),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}