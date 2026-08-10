import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:animate_do/animate_do.dart';
import '../constants.dart';
import '../providers/biofeedback_provider.dart';
import '../services/calendar_service.dart';
import '../widgets/video_stream_widget.dart';
import '../widgets/vitals_card.dart';
import '../widgets/hrv_chart.dart' as hrv_widget;
import '../widgets/interaction_bar.dart' as interaction_widget;
import 'package:permission_handler/permission_handler.dart';
import '../widgets/camera_stream_widget.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final CalendarService _calendar = CalendarService();
  bool _calendarSignedIn = false;

  @override
  void dispose() {
    _calendar.stopPolling();
    super.dispose();
  }

  @override
  void initState() {
  super.initState();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    // BLE / runtime permissions first
    final btScan = await Permission.bluetoothScan.request();
    final btConnect = await Permission.bluetoothConnect.request();
    final bt = await Permission.bluetooth.request();
    final loc = await Permission.locationWhenInUse.request();

    if (!(btScan.isGranted || btScan.isLimited) ||
        !(btConnect.isGranted || btConnect.isLimited) ||
        !(loc.isGranted || loc.isLimited)) {
      if (mounted) {
        _showSnack('Please grant Bluetooth + Location permissions');
      }
    }

    final bio = context.read<BiofeedbackProvider>();
    await bio.initializeAuth();

    final notificationStatus = await Permission.notification.request();
    if (!mounted) return;

    if (notificationStatus.isGranted || notificationStatus.isLimited) {
      await bio.startDataTransfer();
    } else {
      _showSnack(
        'Notifications are recommended for reliable background transfer.',
      );
    }
  });
}

  Future<void> _handleCalendarSignIn() async {
    if (!AppConstants.enableCalendar) {
      _showSnack('Calendar integration is disabled for this build.');
      return;
    }

    final ok = await _calendar.signIn();
    if (ok && mounted) {
      setState(() => _calendarSignedIn = true);
      _calendar.startDailyPlanning((eventName) {
        context.read<BiofeedbackProvider>().fireCalendarTrigger(eventName);
      });
      _showSnack(
        '📅 Calendar connected — '
        '${_calendar.scheduledTriggerCount} '
        'triggers scheduled today',
      );
    } else {
      _showSnack('❌ Calendar sign in failed');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: GoogleFonts.inter(color: Colors.white),
        ),
        backgroundColor: const Color(AppConstants.surfaceColor),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bio = context.watch<BiofeedbackProvider>();
    final s = bio.status;

    return Scaffold(
      backgroundColor: const Color(AppConstants.bgColor),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FadeInDown(
                duration: const Duration(milliseconds: 600),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'BIOFEEDBACK',
                            style: GoogleFonts.inter(
                              color: const Color(AppConstants.accentColor),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 2.0,
                            ),
                          ),
                          Text(
                            'Adaptive Interactions',
                            style: GoogleFonts.inter(
                              color: const Color(AppConstants.textPrimary),
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 500),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: bio.isConnected
                              ? const Color(AppConstants.calmColor)
                              : const Color(AppConstants.stressColor),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        bio.isConnected ? 'LIVE' : 'OFFLINE',
                        style: GoogleFonts.inter(
                          color: bio.isConnected
                              ? const Color(AppConstants.calmColor)
                              : const Color(AppConstants.stressColor),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: FadeInUp(
                  duration: const Duration(milliseconds: 650),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(AppConstants.surfaceColor),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(AppConstants.cardBorder),
                      ),
                    ),
                    child: bio.isInitializing
                        ? Row(
                            children: [
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Restoring session...',
                                  style: GoogleFonts.inter(
                                    color: const Color(AppConstants.textPrimary),
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          )
                        : bio.isAuthenticated
                            ? Row(
                                children: [
                                  const Icon(
                                    Icons.verified_user,
                                    color: Color(AppConstants.calmColor),
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      bio.authMessage.isNotEmpty
                                          ? bio.authMessage
                                          : 'Authenticated',
                                      style: GoogleFonts.inter(
                                        color: const Color(AppConstants.textPrimary),
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: bio.signOut,
                                    child: const Text('Sign out'),
                                  ),
                                ],
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: bio.isSigningIn
                                          ? null
                                          : () async {
                                              final ok = await bio.signInWithGoogle();
                                              if (!mounted) return;
                                              _showSnack(
                                                ok
                                                    ? 'Signed in successfully'
                                                    : 'Google sign-in failed',
                                              );
                                            },
                                      icon: bio.isSigningIn
                                          ? const SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Color(AppConstants.accentColor),
                                              ),
                                            )
                                          : const Icon(Icons.login),
                                      label: Text(
                                        bio.isSigningIn
                                            ? 'Signing in...'
                                            : 'Sign in with Google',
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor:
                                            const Color(AppConstants.accentColor)
                                                .withValues(alpha: 0.15),
                                        foregroundColor:
                                            const Color(AppConstants.accentColor),
                                        side: const BorderSide(
                                          color: Color(AppConstants.accentColor),
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (bio.startupError.isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      bio.startupError,
                                      style: GoogleFonts.inter(
                                        color: const Color(AppConstants.stressColor),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FadeIn(
                duration: const Duration(milliseconds: 800),
                child: const VideoStreamWidget(),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  children: [
                    FadeInUp(
                      duration: const Duration(milliseconds: 600),
                      child: Row(
                        children: [
                          VitalsCard(
                            label: 'HR',
                            value: s != null ? s.avgHr.toStringAsFixed(0) : '--',
                            unit: 'bpm',
                            color: const Color(AppConstants.stressColor),
                            isStressed: s != null && s.avgHr > 90,
                          ),
                          VitalsCard(
                            label: 'HRV',
                            value: s != null ? s.avgHrv.toStringAsFixed(1) : '--',
                            unit: 'ms',
                            color: const Color(AppConstants.calmColor),
                            isStressed: s != null && s.avgHrv < 20,
                          ),
                          VitalsCard(
                            label: 'BR',
                            value: s != null ? s.avgBr.toStringAsFixed(1) : '--',
                            unit: '/min',
                            color: const Color(AppConstants.accentColor),
                            isStressed: false,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    FadeInUp(
                      duration: const Duration(milliseconds: 700),
                      child: interaction_widget.InteractionBar(
                        activeIndex: s?.activeInteraction ?? 0,
                        isHolding: s?.isHolding ?? false,
                        holdProgress: s?.holdProgress ?? 0.0,
                        holdTimeRemaining: s?.holdTimeRemaining ?? '0:00',
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (AppConstants.enableCameraInteraction &&
                        s != null &&
                        s.activeInteraction == 3) ...[
                      const SizedBox(height: 12),
                      FadeInUp(
                        duration: const Duration(milliseconds: 750),
                        child: const CameraStreamWidget(),
                      ),
                    ],
                    FadeInUp(
                      duration: const Duration(milliseconds: 800),
                      child: hrv_widget.HRVChart(
                        hrvData: bio.hrvHistory,
                        hrData: bio.hrHistory,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (bio.triggerMessage.isNotEmpty)
                      FadeInUp(
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: const Color(AppConstants.accentColor)
                                .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(AppConstants.accentColor)
                                  .withValues(alpha: 0.3),
                            ),
                          ),
                          child: Text(
                            bio.triggerMessage,
                            style: GoogleFonts.inter(
                              color: const Color(AppConstants.accentColor),
                              fontSize: 13,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    if (bio.calendarMessage.isNotEmpty)
                      FadeInUp(
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.purple.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.purple.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Text(
                            bio.calendarMessage,
                            style: GoogleFonts.inter(
                              color: Colors.purpleAccent,
                              fontSize: 13,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    FadeInUp(
                      duration: const Duration(milliseconds: 900),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: !bio.isAuthenticated || bio.isTriggerLoading
                              ? null
                              : () => bio.fireManualTrigger(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(AppConstants.accentColor)
                                .withValues(alpha: 0.15),
                            foregroundColor: const Color(AppConstants.accentColor),
                            side: const BorderSide(
                              color: Color(AppConstants.accentColor),
                              width: 1,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(32),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          child: bio.isTriggerLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(AppConstants.accentColor),
                                  ),
                                )
                              : Text(
                                  '⚡  Trigger Interaction',
                                  style: GoogleFonts.inter(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                        ),
                      ),
                    ),
                    if (AppConstants.enableCalendar) ...[
                      const SizedBox(height: 12),
                      FadeInUp(
                        duration: const Duration(milliseconds: 1000),
                        child: SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _calendarSignedIn || !bio.isAuthenticated
                                ? null
                                : _handleCalendarSignIn,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _calendarSignedIn
                                  ? Colors.purple.withValues(alpha: 0.05)
                                  : Colors.purple.withValues(alpha: 0.15),
                              foregroundColor: Colors.purpleAccent,
                              side: BorderSide(
                                color: _calendarSignedIn
                                    ? Colors.purple.withValues(alpha: 0.3)
                                    : Colors.purpleAccent,
                                width: 1,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(32),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                            child: Text(
                              _calendarSignedIn
                                  ? '📅  Calendar Connected'
                                  : '📅  Connect Calendar',
                              style: GoogleFonts.inter(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_calendarSignedIn) ...[
                        const SizedBox(height: 8),
                        FadeInUp(
                          child: SizedBox(
                            width: double.infinity,
                            child: TextButton(
                              onPressed: () async {
                                await _calendar.refreshToday();
                                if (mounted) {
                                  _showSnack(
                                    '🔄 Refreshed — '
                                    '${_calendar.scheduledTriggerCount} '
                                    'triggers scheduled',
                                  );
                                }
                              },
                              style: TextButton.styleFrom(
                                foregroundColor:
                                    const Color(AppConstants.textSecondary),
                              ),
                              child: Text(
                                '🔄  Refresh Today\'s Schedule',
                                style: GoogleFonts.inter(fontSize: 13),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}