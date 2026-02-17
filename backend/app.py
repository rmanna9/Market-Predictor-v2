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
    print("Caricamento modelli...")
    for ticker in TICKERS:
        MODELS[ticker] = joblib.load(f"models/{ticker}_model.pkl")
        print(f"{ticker} caricato")

def get_data_from_db(ticker):
    query = text("""
        SELECT date, price
        FROM market_data
        WHERE ticker = :ticker
        ORDER BY date DESC
        LIMIT 30
    """)
    with engine.connect() as conn:
        df = pd.read_sql(query, conn, params={"ticker": ticker})
    return df.sort_values("date")

@app.get("/predict")
def predict(ticker: str):

    if ticker not in MODELS:
        raise HTTPException(status_code=404)

    model = MODELS[ticker]
    hist_data = get_data_from_db(ticker)

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