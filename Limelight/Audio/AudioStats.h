#pragma once

// Exponentially Weighted Moving Average

class EWMA {
public:
    EWMA();                         // Default constructor with predefined alpha
    EWMA(double alpha);             // Constructor with custom alpha
    double addSample(double input); // Add a sample and compute the new average
    double getOutput() const;       // Retrieve the current average

private:
    static constexpr double DefaultAlpha = 0.1;
    static constexpr double InitialOutput = -1.0;
    double m_output;
    double m_alpha;
};

