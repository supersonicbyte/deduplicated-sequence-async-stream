
struct StockPrice: Hashable {
    let symbol: String
    let price: Double

    func hash(into hasher: inout Hasher) {
        hasher.combine(symbol)
    }

    static func == (lhs: StockPrice, rhs: StockPrice) -> Bool {
        return lhs.symbol == rhs.symbol
    }
}
