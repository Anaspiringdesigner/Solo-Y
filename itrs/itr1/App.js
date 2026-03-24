import React, { useState } from 'react';
import { StyleSheet, Text, View, TouchableOpacity, ActivityIndicator } from 'react-native';
import axios from 'axios';

// Replace this with your computer's IPv4 address!
const SERVER_URL = 'http://10.96.79.170:8080';

export default function App() {
  const [prediction, setPrediction] = useState('Unknown');
  const [confidence, setConfidence] = useState(0);
  const [loading, setLoading] = useState(false);

  // We will mock a sequence for now until we hook up the Casio/Health Connect
  const mockSequence = [[70, 45], [85, 30], [115, 15]];

  // 1. Ask the Brain what we are doing
  const checkBrain = async () => {
    setLoading(true);
    try {
      const response = await axios.post(`${SERVER_URL}/predict`, {
        sequence: mockSequence,
      });
      
      const { predicted_class, confidence_percent } = response.data;
      
      // Map the class numbers to your actual states
      const classNames = {
        1: "Baseline / Sleep",
        2: "Panic / Procrastination",
        3: "Meaningful Focus",
        4: "Inattention / Wandering",
        5: "Rigid Hyperfocus",
        6: "Intervention Needed"
      };

      setPrediction(classNames[predicted_class]);
      setConfidence(confidence_percent);
    } catch (error) {
      alert("Cannot connect to Julia Brain. Check your IP!");
      console.error(error);
    }
    setLoading(false);
  };

  // 2. The Active Learning Function (You tapped a button)
  const sendLabelToBrain = async (labelId) => {
    setLoading(true);
    try {
      const response = await axios.post(`${SERVER_URL}/learn`, {
        sequence: mockSequence,
        label: labelId
      });
      alert(`Brain updated! New error rate: ${response.data.new_error_rate}`);
    } catch (error) {
      alert("Failed to send learning data.");
      console.error(error);
    }
    setLoading(false);
  };

  return (
    <View style={styles.container}>
      <Text style={styles.header}>🧠 ADHD Bio-Brain</Text>
      
      <View style={styles.statusBox}>
        <Text style={styles.label}>Current State:</Text>
        <Text style={styles.stateText}>{prediction}</Text>
        <Text style={styles.confidenceText}>Confidence: {confidence}%</Text>
      </View>

      <TouchableOpacity style={styles.predictButton} onPress={checkBrain}>
        <Text style={styles.buttonText}>
          {loading ? "Thinking..." : "What am I doing?"}
        </Text>
      </TouchableOpacity>

      <Text style={styles.subHeader}>Active Learning: Correct the Brain</Text>
      
      {/* Active Learning Buttons */}
      <View style={styles.grid}>
        <TouchableOpacity style={styles.learnButton} onPress={() => sendLabelToBrain(2)}>
          <Text style={styles.learnText}>I'm Procrastinating</Text>
        </TouchableOpacity>
        
        <TouchableOpacity style={styles.learnButton} onPress={() => sendLabelToBrain(3)}>
          <Text style={styles.learnText}>I'm Focused</Text>
        </TouchableOpacity>

        <TouchableOpacity style={styles.learnButton} onPress={() => sendLabelToBrain(4)}>
          <Text style={styles.learnText}>I'm Wandering</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#f4f4f8', alignItems: 'center', paddingTop: 80, paddingHorizontal: 20 },
  header: { fontSize: 28, fontWeight: 'bold', marginBottom: 30, color: '#333' },
  statusBox: { backgroundColor: '#fff', padding: 30, borderRadius: 15, width: '100%', alignItems: 'center', shadowColor: '#000', shadowOpacity: 0.1, shadowRadius: 10, marginBottom: 30 },
  label: { fontSize: 16, color: '#666', marginBottom: 10 },
  stateText: { fontSize: 24, fontWeight: 'bold', color: '#2c3e50', textAlign: 'center' },
  confidenceText: { fontSize: 16, color: '#e74c3c', marginTop: 10, fontWeight: 'bold' },
  predictButton: { backgroundColor: '#3498db', paddingVertical: 15, paddingHorizontal: 40, borderRadius: 25, marginBottom: 40 },
  buttonText: { color: '#fff', fontSize: 18, fontWeight: 'bold' },
  subHeader: { fontSize: 18, fontWeight: 'bold', color: '#555', marginBottom: 15 },
  grid: { flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'space-between', width: '100%' },
  learnButton: { backgroundColor: '#2ecc71', padding: 15, borderRadius: 10, width: '48%', marginBottom: 15, alignItems: 'center' },
  learnText: { color: '#fff', fontWeight: 'bold' }
});