import TaxSuite "../src/backend/TaxTest";
import LedgerSuite "../src/backend/LedgerTest";

await TaxSuite.run();
await LedgerSuite.run();
