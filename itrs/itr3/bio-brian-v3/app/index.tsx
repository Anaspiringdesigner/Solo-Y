import React, { useState, useEffect } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, PermissionsAndroid, Platform } from 'react-native';
import { BleManager } from 'react-native-ble-plx';
import { Buffer } from 'buffer';
import notifee, { AndroidImportance } from '@notifee/react-native';
import * as SQLite from 'expo-sqlite';

const bleManager = new BleManager();
const HR_SERVICE_UUID = '0000180d-0000-1000-8000-00805f9b34fb';
const HR_CHAR_UUID = '00002a37-0000-1000-8000-00805f9b34fb';

// --- DATABASE SETUP ---
// Open the database and create a fresh table for our 4 data points
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

// --- BACKGROUND SERVICE SETUP ---
notifee.registerForegroundService((notification) => {
  return new Promise(() => {
    console.log("Foreground service is running...");
  });
});

export default function App() {
  const [connectionStatus, setConnectionStatus] = useState('Disconnected');
  const [heartRate, setHeartRate] = useState(0);
  const [latestRR, setLatestRR] = useState(0);
  const [logData, setLogData] = useState<any[]>([]); // Holds our DB rows for the UI

  useEffect(() => {
    requestPermissions();
    return () => {
      bleManager.destroy();
      stopForegroundService();
    };
  }, []);

  const requestPermissions = async () => {
    if (Platform.OS === 'android') {
      await PermissionsAndroid.requestMultiple([
        PermissionsAndroid.PERMISSIONS.BLUETOOTH_SCAN,
        PermissionsAndroid.PERMISSIONS.BLUETOOTH_CONNECT,
        PermissionsAndroid.PERMISSIONS.ACCESS_FINE_LOCATION,
        PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS,
      ]);
    }
  };

  const startForegroundService = async () => {
    const channelId = await notifee.createChannel({
      id: 'bio-brain-tracker',
      name: 'Bio-Brain HRV Tracker',
      importance: AndroidImportance.HIGH,
    });

    await notifee.displayNotification({
      title: '🧠 Bio-Brain Active',
      body: 'Monitoring HRV and Heart Rate...',
      android: {
        channelId,
        asForegroundService: true,
        ongoing: true,
      },
    });
  };

  const stopForegroundService = async () => {
    await notifee.stopForegroundService();
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

  // --- FIXED: Single connectToDevice function with Auto-Reconnect ---
  const connectToDevice = async (device: any) => {
    try {
      const connectedDevice = await device.connect();
      setConnectionStatus(`Connected to ${device.name}`);
      await connectedDevice.discoverAllServicesAndCharacteristics();
      
      await startForegroundService();

      // The Auto-Reconnect Listener
      bleManager.onDeviceDisconnected(device.id, (error, disconnectedDevice) => {
        console.warn("Device disconnected! Attempting to reconnect...");
        setConnectionStatus('Connection lost. Reconnecting...');
        stopForegroundService();
        
        setTimeout(() => {
          scanAndConnect();
        }, 3000);
      });

      connectedDevice.monitorCharacteristicForService(
        HR_SERVICE_UUID,
        HR_CHAR_UUID,
        (error, characteristic) => {
          if (error) {
            console.error("Stream Error:", error);
            return;
          }
          if (characteristic?.value) {
            parseHeartRateData(characteristic.value);
          }
        }
      );
    } catch (error) {
      console.error("Connection Failed:", error);
      setConnectionStatus('Connection Failed. Retrying...');
      
      setTimeout(() => {
        scanAndConnect();
      }, 5000);
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
        
        // --- SAVE TO DATABASE ---
        const timestamp = Date.now();
        db.runSync(
          'INSERT INTO bio_data (timestamp, hrv, heart_rate, label) VALUES (?, ?, ?, ?)',
          [timestamp, rrInMs, hrValue, 'unlabeled']
        );

        offset += 2;
      }
    }
  };

  // --- DATABASE VAULT FUNCTIONS ---
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
      console.log("Database cleared!");
    } catch (error) {
      console.error("Failed to clear database:", error);
    }
  };

  return (
    <View style={styles.container}>
      <Text style={styles.header}>🧠 Bio-Brain V3</Text>
      
      <View style={styles.statusBox}>
        <Text style={styles.label}>Status: {connectionStatus}</Text>
        <Text style={styles.dataText}>BPM: {heartRate}</Text>
        <Text style={styles.dataText}>Latest RR: {latestRR} ms</Text>
      </View>

      <TouchableOpacity style={styles.button} onPress={scanAndConnect}>
        <Text style={styles.buttonText}>Pair & Run in Background</Text>
      </TouchableOpacity>

      {/* --- DATABASE VAULT UI --- */}
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

        {logData.map((row, index) => (
          <View key={index} style={styles.dataRow}>
            <Text style={styles.rowText}>HR: {row.heart_rate} | HRV: {row.hrv}ms</Text>
            <Text style={styles.rowLabel}>Label: {row.label}</Text>
          </View>
        ))}
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
  button: { backgroundColor: '#2ecc71', paddingVertical: 15, paddingHorizontal: 40, borderRadius: 25 },
  buttonText: { color: '#fff', fontSize: 18, fontWeight: 'bold' },
  
  // New Styles for Database Vault
  dbSection: { marginTop: 30, width: '100%', alignItems: 'center' },
  subHeader: { fontSize: 20, fontWeight: 'bold', color: '#333', marginBottom: 15 },
  row: { flexDirection: 'row', justifyContent: 'space-between', width: '100%', marginBottom: 15 },
  dbButton: { backgroundColor: '#9b59b6', paddingVertical: 10, paddingHorizontal: 15, borderRadius: 10, width: '48%', alignItems: 'center' },
  buttonTextSmall: { color: '#fff', fontSize: 14, fontWeight: 'bold' },
  dataRow: { backgroundColor: '#fff', width: '100%', padding: 10, borderRadius: 8, marginBottom: 5, borderLeftWidth: 4, borderLeftColor: '#3498db' },
  rowText: { fontSize: 16, fontWeight: 'bold', color: '#2c3e50' },
  rowLabel: { fontSize: 12, color: '#7f8c8d', marginTop: 2 },
});