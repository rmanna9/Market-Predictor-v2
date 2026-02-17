import streamlit as st
import requests
import pandas as pd

BACKEND_URL = "http://backend:8000/predict"

st.title("📈 Secure Market Predictor")

ticker = st.selectbox("Seleziona ticker", ["AAPL", "BTC-USD", "SPY"])

if st.button("Genera Analisi"):

    response = requests.get(
        BACKEND_URL,
        params={"ticker": ticker}
    )

    if response.status_code == 200:
        data = response.json()

        st.metric(
            label=f"{ticker}",
            value=f"${data['prediction']}",
            delta=data['delta']
        )

        df = pd.DataFrame(data["history"])
        df["date"] = pd.to_datetime(df["date"])
        df.set_index("date", inplace=True)

        st.line_chart(df["price"])
    else:
        st.error("Errore nel backend")