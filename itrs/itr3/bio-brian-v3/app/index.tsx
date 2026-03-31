import React, { useState, useEffect, useRef } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, PermissionsAndroid, Platform, ScrollView } from 'react-native';
import { BleManager, Device } from 'react-native-ble-plx';
import { Buffer } from 'buffer';
import * as SQLite from 'expo-sqlite';

const bleManager = new BleManager();

const HR_SERVICE_UUID = '0000180d-0000-1000-8000-00805f9b34fb';
const HR_CHAR_UUID = '00002a37-0000-1000-8000-00805f9b34fb';

export default function App() {
  const [connectionStatus, setConnectionStatus] = useState('Disconnected');
  const [heartRate, setHeartRate] = useState(0);
  const [history, setHistory] = useState<any[]>([]);
  const [isDbReady, setIsDbReady] = useState(false);
  
  // Using a ref for the DB to ensure the interval can always see the latest instance
  const dbRef = useRef<SQLite.SQLiteDatabase | null>(null);
  const latestHR = useRef(0);
  const latestRR = useRef(0);
  const logInterval = useRef<NodeJS.Timeout | null>(null);

  useEffect(() => {
    const prepare = async () => {
      await setupDatabase();
      await requestPermissions();
    };
    prepare();

    return () => {
      if (logInterval.current) clearInterval(logInterval.current);
      bleManager.stopDeviceScan();
    };
  }, []);

  // Separate effect to start the clock only when DB is actually ready
  useEffect(() => {
    if (isDbReady) {
      console.log("Starting 1Hz Clock...");
      logInterval.current = setInterval(() => {
        if (latestHR.current > 0) {
          saveSnapShot();
        }
      }, 1000);
    }
    return () => {
      if (logInterval.current) clearInterval(logInterval.current);
    };
  }, [isDbReady]);

  const setupDatabase = async () => {
    try {
      const database = await SQLite.openDatabaseAsync('BioBrain.db');
      await database.execAsync(`
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS heart_data (
          id INTEGER PRIMARY KEY AUTOINCREMENT, 
          timestamp TEXT, 
          heart_rate INTEGER, 
          rr_value INTEGER
        );
      `);
      dbRef.current = database;
      setIsDbReady(true);
      console.log("Database initialized successfully.");
    } catch (e) {
      console.error("Database initialization failed:", e);
    }
  };

  const requestPermissions = async () => {
    if (Platform.OS === 'android') {
      await PermissionsAndroid.requestMultiple([
        PermissionsAndroid.PERMISSIONS.BLUETOOTH_SCAN,
        PermissionsAndroid.PERMISSIONS.BLUETOOTH_CONNECT,
        PermissionsAndroid.PERMISSIONS.ACCESS_FINE_LOCATION,
      ]);
    }
  };

  const saveSnapShot = async () => {
    // Crucial Guard: prevents NullPointerException
    if (!dbRef.current) return;

    const hr = latestHR.current;
    const rr = latestRR.current;
    const timeStr = new Date().toLocaleTimeString([], { hour12: false });

    try {
      await dbRef.current.runAsync(
        'INSERT INTO heart_data (timestamp, heart_rate, rr_value) VALUES (?, ?, ?)',
        [timeStr, hr, rr]
      );
    } catch (e) {
      console.error("Snapshot Save Error:", e);
    }
  };

  const fetchLastFive = async () => {
    if (!dbRef.current) return;
    try {
      const allRows: any[] = await dbRef.current.getAllAsync('SELECT * FROM heart_data ORDER BY id DESC LIMIT 5');
      setHistory(allRows);
    } catch (e) {
      console.error("Fetch Error:", e);
    }
  };

  const connectToDevice = async (device: Device) => {
    try {
      const peripheral = await device.connect();
      setConnectionStatus(`Connected: ${device.name}`);
      await peripheral.discoverAllServicesAndCharacteristics();
      
      peripheral.monitorCharacteristicForService(HR_SERVICE_UUID, HR_CHAR_UUID, (error, char) => {
        if (error || !char?.value) return;

        const buffer = Buffer.from(char.value, 'base64');
        const flags = buffer.readUInt8(0);
        const is16Bit = (flags & 0x01) !== 0;
        const currentHR = is16Bit ? buffer.readUInt16LE(1) : buffer.readUInt8(1);
        
        latestHR.current = currentHR;
        setHeartRate(currentHR);

        let offset = is16Bit ? 3 : 2;
        if ((flags & 0x08) !== 0) offset += 2;

        while (offset + 1 < buffer.length) {
          latestRR.current = buffer.readUInt16LE(offset);
          offset += 2;
        }
      });
    } catch (e) {
      setConnectionStatus('Connect Error');
    }
  };

  const scanAndConnect = () => {
    bleManager.stopDeviceScan();
    setConnectionStatus('Scanning...');
    bleManager.startDeviceScan(null, null, (error, device) => {
      if (device?.name?.includes('Polar H10')) {
        bleManager.stopDeviceScan();
        connectToDevice(device);
      }
    });
  };

  return (
    <ScrollView contentContainerStyle={styles.container}>
      <Text style={styles.header}>🧪 Bio-Brain 1Hz Engine</Text>
      
      <View style={styles.statusBox}>
        <Text style={styles.dataText}>{heartRate} BPM</Text>
        <Text style={styles.label}>{connectionStatus}</Text>
        <Text style={isDbReady ? styles.dbActive : styles.dbInactive}>
          DB Status: {isDbReady ? 'Ready' : 'Initializing...'}
        </Text>
      </View>

      <TouchableOpacity style={styles.button} onPress={scanAndConnect}>
        <Text style={styles.buttonText}>Connect Sensor</Text>
      </TouchableOpacity>

      <View style={styles.historySection}>
        <TouchableOpacity style={styles.historyButton} onPress={fetchLastFive}>
          <Text style={styles.buttonText}>Refresh History</Text>
        </TouchableOpacity>
        
        <View style={styles.tableHeader}>
          <Text style={styles.colHeader}>Time</Text>
          <Text style={styles.colHeader}>HR</Text>
          <Text style={styles.colHeader}>RR</Text>
        </View>

        {history.map((item) => (
          <View key={item.id} style={styles.historyRow}>
            <Text style={styles.cell}>{item.timestamp}</Text>
            <Text style={[styles.cell, { color: '#e74c3c', fontWeight: 'bold' }]}>{item.heart_rate}</Text>
            <Text style={styles.cell}>{item.rr_value}</Text>
          </View>
        ))}
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flexGrow: 1, backgroundColor: '#121212', padding: 20, alignItems: 'center' },
  header: { fontSize: 24, fontWeight: 'bold', color: '#fff', marginTop: 40, marginBottom: 20 },
  statusBox: { backgroundColor: '#1e1e1e', padding: 25, borderRadius: 20, width: '100%', alignItems: 'center', marginBottom: 20 },
  label: { fontSize: 14, color: '#888', marginTop: 10 },
  dbActive: { fontSize: 12, color: '#2ecc71', marginTop: 5 },
  dbInactive: { fontSize: 12, color: '#f1c40f', marginTop: 5 },
  dataText: { fontSize: 52, fontWeight: 'bold', color: '#e74c3c' },
  button: { backgroundColor: '#2980b9', padding: 15, width: '100%', borderRadius: 12, alignItems: 'center' },
  buttonText: { color: '#fff', fontSize: 16, fontWeight: 'bold' },
  historySection: { width: '100%', marginTop: 30 },
  historyButton: { backgroundColor: '#27ae60', padding: 12, borderRadius: 8, alignItems: 'center', marginBottom: 15 },
  tableHeader: { flexDirection: 'row', paddingHorizontal: 10, marginBottom: 10 },
  colHeader: { color: '#888', flex: 1, textAlign: 'center', fontSize: 12 },
  historyRow: { flexDirection: 'row', backgroundColor: '#1e1e1e', padding: 12, borderRadius: 8, marginBottom: 5 },
  cell: { color: '#fff', flex: 1, textAlign: 'center', fontSize: 14 }
});