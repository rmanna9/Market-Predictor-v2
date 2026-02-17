from fastapi import FastAPI, HTTPException
import joblib
import os
import pandas as pd
from datetime import datetime, timedelta
from sqlalchemy import create_engine, text

DB_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://user_secure:password_cloud@db:5432/market_db"
)

engine = create_engine(DB_URL)

app = FastAPI()

MODELS = {}
TICKERS = ["AAPL", "BTC-USD", "SPY"]

@app.on_event("startup")
def load_models():
    for ticker in TICKERS:
        try:
            path = f"models/{ticker}_model.pkl"
            if os.path.exists(path):
                MODELS[ticker] = joblib.load(path)
                print(f"Modello {ticker} caricato con successo")
            else:
                print(f"ATTENZIONE: File modello per {ticker} mancante")
        except Exception as e:
            print(f"Errore critico nel caricamento di {ticker}: {e}")

def get_data_from_db(ticker):
    try:
        query = text("""
            SELECT date, price
            FROM market_data
            WHERE ticker = :ticker
            ORDER BY date DESC
            LIMIT 30
        """)
        with engine.connect() as conn:
            df = pd.read_sql(query, conn, params={"ticker": ticker})
        
        if df.empty:
            return None
        return df.sort_values("date")
    except Exception as e:
        print(f"Errore database: {e}")
        return None



@app.get("/predict")
def predict(ticker: str):
    if ticker not in MODELS:
        raise HTTPException(status_code=404, detail=f"Modello per {ticker} non trovato")

    hist_data = get_data_from_db(ticker)
    
    if hist_data is None or len(hist_data) == 0:
        raise HTTPException(
            status_code=503, 
            detail="Dati storici non disponibili. Ingestione in corso o database non raggiungibile."
        )

    try:
        model = MODELS[ticker]
        tomorrow = datetime.now() + timedelta(days=1)
        future_df = pd.DataFrame({'ds': [tomorrow]})
        
        forecast = model.predict(future_df)
        pred_val = float(forecast.iloc[0]['yhat'])
        last_price = float(hist_data['price'].iloc[-1])
        delta = pred_val - last_price

        return {
            "ticker": ticker,
            "prediction": round(pred_val, 2),
            "delta": round(delta, 2),
            "history": hist_data.to_dict(orient="records")
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Errore durante la predizione: {str(e)}")