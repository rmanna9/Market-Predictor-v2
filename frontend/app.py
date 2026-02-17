import os
import streamlit as st
import pandas as pd
import requests
from datetime import datetime, timedelta

st.set_page_config(page_title="Stock Market Predictor", page_icon="📈", layout="wide")

BACKEND_URL = f"{os.getenv('BACKEND_URL', 'http://backend-service:8000')}/predict"
tomorrow = datetime.now() + timedelta(days=1)

st.title("📈 Stock Market Predictor")

@st.cache_data(ttl=600, show_spinner=False)
def get_prediction(ticker):
    """
    Richiama il backend solo la prima volta per ogni ticker.
    Il risultato viene memorizzato in cache per 10 minuti.
    """
    try:
        response = requests.get(BACKEND_URL, params={"ticker": ticker})
        if response.status_code == 200:
            return response.json()
        else:
            return {"error": response.json().get("detail", "Errore sconosciuto")}
    except Exception as e:
        return {"error": str(e)}

# Layout
cols_layout = st.columns([1, 3])
left_col = cols_layout[0]
right_col = cols_layout[1]

with left_col.container(border=True, height="stretch", vertical_alignment="top"):
    st.subheader("Seleziona i ticker")
    available_tickers = ["AAPL", "BTC-USD", "SPY"]
    selected_tickers = []

    cols_selection = st.columns(len(available_tickers))
    for i, ticker in enumerate(available_tickers):
        is_selected = cols_selection[i].checkbox(ticker, value=True)
        if is_selected:
            selected_tickers.append(ticker)

    if not selected_tickers:
        st.warning("Seleziona almeno un ticker.")
        st.stop()

    st.write("")
    st.subheader("Orizzonte temporale")
    horizon_options = {
        "1 Mese": 30,
        "2 Mesi": 60,
        "3 Mesi": 90,
        "6 Mesi": 180,
        "1 Anno": 365,
        "2 Anni": 730,
    }
    selected_horizon = st.pills(
        "Seleziona orizzonte",
        options=list(horizon_options.keys()),
        default="1 Anno"
    )
    days = horizon_options[selected_horizon]

with right_col.container(border=True, height="stretch", vertical_alignment="top"):
    st.subheader(f"🔮 Previsioni per il: {tomorrow.strftime('%d/%m/%Y')}")

    df_history = pd.DataFrame()
    df_forecast = pd.DataFrame()

    for ticker in selected_tickers:
        data = get_prediction(ticker)

        if "error" in data:
            st.error(f"{ticker}: {data['error']}")
            continue

        pred_val = data["prediction"]
        delta_val = data["delta"]
        history = pd.DataFrame(data["history"])

        # Metriche per ciascun ticker
        st.metric(label=f"Target {ticker}", value=f"${pred_val}", delta=f"{delta_val}")

        # Prepara dati per grafico
        temp_hist = history.rename(columns={"price": f"{ticker} (Storico)", "date": "Date"})
        temp_hist['Date'] = pd.to_datetime(temp_hist['Date'])

        last_date = temp_hist['Date'].iloc[-1]
        last_price = float(temp_hist[f"{ticker} (Storico)"].iloc[-1])

        pred_entry = pd.DataFrame({
            'Date': [last_date, tomorrow],
            f"{ticker} (Previsione)": [last_price, pred_val]
        })

        # Filtraggio secondo l'orizzonte selezionato
        cutoff_date = pd.Timestamp.now() - pd.Timedelta(days=days)
        temp_hist_filtered = temp_hist[temp_hist['Date'] >= cutoff_date]
        pred_entry_filtered = pred_entry[pred_entry['Date'] >= cutoff_date]

        if df_history.empty:
            df_history = temp_hist_filtered
            df_forecast = pred_entry_filtered
        else:
            df_history = pd.merge(df_history, temp_hist_filtered, on='Date', how='outer')
            df_forecast = pd.merge(df_forecast, pred_entry_filtered, on='Date', how='outer')

    # Grafico finale
    if not df_history.empty:
        final_df = pd.merge(df_history, df_forecast, on='Date', how='outer').set_index('Date')
        st.line_chart(final_df)

st.divider()
st.caption("Secure Cloud Computing a.a 2025/2026 - Progetto Stock Market Predictor")