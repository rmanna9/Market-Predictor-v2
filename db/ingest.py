import yfinance as yf
from sqlalchemy import create_engine, text
import os

DB_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://user_secure:password_cloud@db:5432/market_db"
)

def ingest_tickers():
    tickers = ["AAPL", "BTC-USD", "SPY"]
    engine = create_engine(DB_URL)

    # Creazione dello schema
    with engine.connect() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS market_data (
                date TIMESTAMP,
                price FLOAT,
                ticker VARCHAR(10)
            );
        """))
        conn.commit()

    for ticker in tickers:
        print(f"Scaricamento dati per {ticker}...")
        df = yf.download(ticker, period="2y", interval="1d")
        df = df[['Close']].reset_index()
        df.columns = ['date', 'price']
        df['ticker'] = ticker

        df.to_sql('market_data', engine, if_exists='append', index=False)
        print(f"Database popolato per {ticker}")

if __name__ == "__main__":
    ingest_tickers()