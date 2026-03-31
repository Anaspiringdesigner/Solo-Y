import { StyleSheet, Text, View, Button, Alert } from 'react-native';
import { ping } from './modules/polar-ble';

export default function App() {
  const testModule = () => {
    // Call the Kotlin function!
    const response = ping();
    Alert.alert("Bridge Status", response);
  };

  return (
    <View style={styles.container}>
      <Text style={styles.title}>AI Polar Setup: 0.618-v1</Text>
      <Button title="Test Polar Bridge" onPress={testModule} />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, justifyContent: 'center', alignItems: 'center' },
  title: { fontSize: 20, marginBottom: 20, fontWeight: 'bold' }
});