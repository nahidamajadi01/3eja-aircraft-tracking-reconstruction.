# 1. Import the tools
from pathlib import Path
import pandas as pd
import duckdb

# 2. Find the spreadsheet beside this Python file
project_folder = Path(__file__).resolve().parent
spreadsheet_path = project_folder / "aviation_project.xlsx"

# 3. Read the spreadsheet, keeping identifiers as text
fleet_data = pd.read_excel(spreadsheet_path, dtype=str)

# 4. Display the column names and first five rows
print("Column names:")
print(fleet_data.columns.tolist())

print("\nFirst five rows:")
print(fleet_data.head().to_string(index=False))
# 5. Open a database file in the project folder
database_path = project_folder / "aviation.duckdb"
connection = duckdb.connect(str(database_path))

# 6. Make the Python table available to SQL
connection.register("fleet_input", fleet_data)

# 7. Save the records as a database table
connection.execute("""
    CREATE OR REPLACE TABLE raw_faa_fleet AS
    SELECT *
    FROM fleet_input
""")

# 8. Check how many rows were saved
row_count = connection.execute("""
    SELECT COUNT(*)
    FROM raw_faa_fleet
""").fetchone()[0]

print(f"\nRows saved to DuckDB: {row_count}")

connection.close()