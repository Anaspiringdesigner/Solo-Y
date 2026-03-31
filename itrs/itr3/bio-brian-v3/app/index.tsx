import React, { useState, useEffect } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, PermissionsAndroid, Platform } from 'react-native';
import { BleManager } from 'react-native-ble-plx';
import { Buffer } from 'buffer';
import * as SQLite from 'expo-sqlite';
import * as Location from 'expo-location';
import * as TaskManager from 'expo-task-manager';
import notifee, { AndroidImportance } from '@notifee/react-native';

const bleManager = new BleManager();
const HR_SERVICE_UUID = '0000180d-0000-1000-8000-00805f9b34fb';
const HR_CHAR_UUID = '00002a37-0000-1000-8000-00805f9b34fb';

// --- THE NUCLEAR OPTION: GPS GOD MODE ---
const LOCATION_TASK_NAME = 'background-location-task';

TaskManager.defineTask(LOCATION_TASK_NAME, ({ data, error }) => {
  if (error) {
    console.error("GPS Task Error:", error);
    return;
  }
  if (data) {
    // This is the true heartbeat. By receiving GPS updates in the background,
    // Android is forced to keep our entire JavaScript thread (and Bluetooth) completely awake!
    console.log("🛡️ God Mode Ping: Thread kept alive by GPS.");
  }
});

// --- DATABASE SETUP ---
const db = SQLite.openDatabaseSync('biobrain.db');
db.execSync(`
  CREATE TABLE IF NOT EXISTS bio_data (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER,
    hrv INTEGER,
    heart_rate INTEGER,
    label TEXT
  );
`);

export default function App() {
  const [connectionStatus, setConnectionStatus] = useState('Disconnected');
  const [heartRate, setHeartRate] = useState(0);
  const [latestRR, setLatestRR] = useState(0);
  const [logData, setLogData] = useState<any[]>([]);

  useEffect(() => {
    requestPermissions();
    return () => {
      stopGodMode();
    };
  }, []);

  const requestPermissions = async () => {
    if (Platform.OS === 'android') {
      // 1. Bluetooth Permissions
      await PermissionsAndroid.requestMultiple([
        PermissionsAndroid.PERMISSIONS.BLUETOOTH_SCAN,
        PermissionsAndroid.PERMISSIONS.BLUETOOTH_CONNECT,
        PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS,
      ]);

      // 2. GPS God Mode Permissions (Must be requested sequentially)
      const { status: fgStatus } = await Location.requestForegroundPermissionsAsync();
      if (fgStatus === 'granted') {
        await Location.requestBackgroundPermissionsAsync();
      }
    }
  };

  const startGodMode = async () => {
    // 1. Show the ongoing notification
    const channelId = await notifee.createChannel({
      id: 'bio-brain-tracker',
      name: 'Bio-Brain HRV Tracker',
      importance: AndroidImportance.HIGH,
    });

    await notifee.displayNotification({
      title: '🧠 Bio-Brain Active',
      body: 'Tracking HRV & maintaining God Mode...',
      android: { channelId, asForegroundService: true, ongoing: true },
    });

    // 2. Start the background GPS tracker to shield the thread
    await Location.startLocationUpdatesAsync(LOCATION_TASK_NAME, {
      accuracy: Location.Accuracy.Low, // We don't need exact GPS, just the ping
      timeInterval: 15000, // Ping every 15 seconds
      distanceInterval: 0,
      showsBackgroundLocationIndicator: false,
    });
  };

  const stopGodMode = async () => {
    await notifee.stopForegroundService();
    const hasStarted = await Location.hasStartedLocationUpdatesAsync(LOCATION_TASK_NAME);
    if (hasStarted) {
      await Location.stopLocationUpdatesAsync(LOCATION_TASK_NAME);
    }
  };

  const scanAndConnect = () => {
    setConnectionStatus('Scanning for Polar H10...');
    
    bleManager.startDeviceScan(null, null, (error, device) => {
      if (error) {
        console.error("Scan Error:", error);
        setConnectionStatus('Scan Error');
        return;
      }

      if (device && device.name && device.name.includes('Polar H10')) {
        bleManager.stopDeviceScan();
        setConnectionStatus('Connecting...');
        connectToDevice(device);
      }
    });
  };

  const connectToDevice = async (device: any) => {
    try {
      const connectedDevice = await device.connect();
      setConnectionStatus(`Connected to ${device.name}`);
      await connectedDevice.discoverAllServicesAndCharacteristics();
      
      await startGodMode();

      bleManager.onDeviceDisconnected(device.id, (error, disconnectedDevice) => {
        console.warn("Device disconnected! Attempting to reconnect...");
        setConnectionStatus('Connection lost. Reconnecting...');
        stopGodMode();
        
        setTimeout(() => { scanAndConnect(); }, 3000);
      });

      connectedDevice.monitorCharacteristicForService(
        HR_SERVICE_UUID,
        HR_CHAR_UUID,
        (error, characteristic) => {
          if (error) return;
          if (characteristic?.value) {
            parseHeartRateData(characteristic.value);
          }
        }
      );
    } catch (error) {
      setConnectionStatus('Connection Failed. Retrying...');
      setTimeout(() => { scanAndConnect(); }, 5000);
    }
  };

  const parseHeartRateData = (base64String: string) => {
    const buffer = Buffer.from(base64String, 'base64');
    const flags = buffer.readUInt8(0);
    const is16BitHR = (flags & 0x01) !== 0;
    
    const hrValue = is16BitHR ? buffer.readUInt16LE(1) : buffer.readUInt8(1);
    setHeartRate(hrValue);

    const rrIntervalPresent = (flags & 0x10) !== 0;
    if (rrIntervalPresent) {
      let offset = is16BitHR ? 3 : 2;
      while (offset < buffer.length) {
        const rrValue = buffer.readUInt16LE(offset);
        const rrInMs = Math.round((rrValue / 1024.0) * 1000.0); 
        setLatestRR(rrInMs);
        
        const timestamp = Date.now();
        db.runSync(
          'INSERT INTO bio_data (timestamp, hrv, heart_rate, label) VALUES (?, ?, ?, ?)',
          [timestamp, rrInMs, hrValue, 'unlabeled']
        );
        offset += 2;
      }
    }
  };

  const fetchDatabaseLogs = () => {
    try {
      const rows = db.getAllSync('SELECT * FROM bio_data ORDER BY timestamp DESC LIMIT 5');
      setLogData(rows);
    } catch (error) {
      console.error("Failed to fetch logs:", error);
    }
  };

  const clearDatabase = () => {
    try {
      db.execSync('DELETE FROM bio_data');
      setLogData([]);
    } catch (error) {}
  };

  return (
    <View style={styles.container}>
      <Text style={styles.header}>🧠 Bio-Brain V3 (God Mode)</Text>
      
      <View style={styles.statusBox}>
        <Text style={styles.label}>Status: {connectionStatus}</Text>
        <Text style={styles.dataText}>BPM: {heartRate}</Text>
        <Text style={styles.dataText}>Latest RR: {latestRR} ms</Text>
      </View>

      <TouchableOpacity style={styles.button} onPress={scanAndConnect}>
        <Text style={styles.buttonText}>Pair & Run in Background</Text>
      </TouchableOpacity>

      <View style={styles.dbSection}>
        <Text style={styles.subHeader}>🗄️ Local Database Vault</Text>
        
        <View style={styles.row}>
          <TouchableOpacity style={styles.dbButton} onPress={fetchDatabaseLogs}>
            <Text style={styles.buttonTextSmall}>Fetch Last 5 Beats</Text>
          </TouchableOpacity>
          
          <TouchableOpacity style={[styles.dbButton, { backgroundColor: '#e74c3c' }]} onPress={clearDatabase}>
            <Text style={styles.buttonTextSmall}>Clear DB</Text>
          </TouchableOpacity>
        </View>

        {logData.map((row, index) => {
          const timeString = new Date(row.timestamp).toLocaleTimeString();
          return (
            <View key={index} style={styles.dataRow}>
              <Text style={styles.rowText}>[{timeString}] HR: {row.heart_rate} | HRV: {row.hrv}ms</Text>
              <Text style={styles.rowLabel}>Label: {row.label}</Text>
            </View>
          );
        })}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#f4f4f8', alignItems: 'center', justifyContent: 'center', padding: 20 },
  header: { fontSize: 28, fontWeight: 'bold', marginBottom: 20, color: '#333', marginTop: 40 },
  statusBox: { backgroundColor: '#fff', padding: 20, borderRadius: 15, width: '100%', alignItems: 'center', shadowColor: '#000', shadowOpacity: 0.1, shadowRadius: 10, marginBottom: 20 },
  label: { fontSize: 16, color: '#666', marginBottom: 10, fontWeight: 'bold' },
  dataText: { fontSize: 32, fontWeight: 'bold', color: '#e74c3c', marginVertical: 5 },
  button: { backgroundColor: '#2ecc71', paddingVertical: 15, paddingHorizontal: 40, borderRadius: 25, marginBottom: 20 },
  buttonText: { color: '#fff', fontSize: 18, fontWeight: 'bold' },
  dbSection: { width: '100%', alignItems: 'center' },
  subHeader: { fontSize: 20, fontWeight: 'bold', color: '#333', marginBottom: 15 },
  row: { flexDirection: 'row', justifyContent: 'space-between', width: '100%', marginBottom: 15 },
  dbButton: { backgroundColor: '#9b59b6', paddingVertical: 10, paddingHorizontal: 15, borderRadius: 10, width: '48%', alignItems: 'center' },
  buttonTextSmall: { color: '#fff', fontSize: 14, fontWeight: 'bold' },
  dataRow: { backgroundColor: '#fff', width: '100%', padding: 10, borderRadius: 8, marginBottom: 5, borderLeftWidth: 4, borderLeftColor: '#3498db' },
  rowText: { fontSize: 16, fontWeight: 'bold', color: '#2c3e50' },
  rowLabel: { fontSize: 12, color: '#7f8c8d', marginTop: 2 },
});