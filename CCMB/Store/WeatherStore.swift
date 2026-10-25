import CoreLocation
import Foundation

@MainActor
final class WeatherStore: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct HourlyForecast: Identifiable, Sendable {
        var id: String { timeIso }
        let timeIso: String
        let timeLabel: String
        let hour: Int
        let temperature: Double
        let weatherCode: Int
        let symbolName: String
        let precipitationProbability: Int?
    }

    struct DailyForecast: Identifiable, Sendable {
        var id: String { dateIso }
        let dateIso: String
        let dayLabel: String
        let weatherCode: Int
        let symbolName: String
        let maxTemp: Double
        let minTemp: Double
        let precipitationProbability: Int?
    }

    struct Reading: Sendable {
        let temperature: Double
        let weatherCode: Int
        let symbolName: String
        let hourly: [HourlyForecast]
        let daily: [DailyForecast]
        let updatedAt: Date
        let isStale: Bool
        let errorMessage: String?

        // iPhone dashboard compatibility initializer
        init(
            temperature: Double,
            weatherCode: Int = 0,
            symbolName: String,
            hourly: [HourlyForecast] = [],
            daily: [DailyForecast] = [],
            updatedAt: Date = Date(),
            isStale: Bool = false,
            errorMessage: String? = nil
        ) {
            self.temperature = temperature
            self.weatherCode = weatherCode
            self.symbolName = symbolName
            self.hourly = hourly
            self.daily = daily
            self.updatedAt = updatedAt
            self.isStale = isStale
            self.errorMessage = errorMessage
        }
    }

    @Published private(set) var reading: Reading?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let locationManager = CLLocationManager()
    private var isForeground = true
    private var lastCoordinate: CLLocationCoordinate2D?
    private var refreshTask: Task<Void, Never>?
    private var currentRequestId = 0

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        authorizationStatus = locationManager.authorizationStatus
    }

    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    func pause() {
        isForeground = false
        currentRequestId &+= 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    func resume() {
        let wasPaused = !isForeground
        isForeground = true
        if wasPaused {
            refresh()
        }
    }

    func refresh() {
        guard isForeground else { return }
        authorizationStatus = locationManager.authorizationStatus
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        case .denied, .restricted:
            reading = nil
        @unknown default:
            reading = nil
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        guard isForeground else { return }
        if manager.authorizationStatus == .authorizedAlways ||
            manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isForeground, let location = locations.last else { return }
        lastCoordinate = location.coordinate

        // If an active fetch task is already in-flight, do not cancel and restart it
        // on duplicate location callbacks.
        if refreshTask != nil {
            return
        }

        currentRequestId &+= 1
        let requestId = currentRequestId
        refreshTask = Task { [weak self] in
            await self?.fetchWeather(at: location.coordinate, requestId: requestId)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard isForeground else { return }
        if let current = reading {
            reading = Reading(
                temperature: current.temperature,
                weatherCode: current.weatherCode,
                symbolName: current.symbolName,
                hourly: current.hourly,
                daily: current.daily,
                updatedAt: current.updatedAt,
                isStale: true,
                errorMessage: "날씨 정보를 불러올 수 없습니다"
            )
        }
    }

    private func fetchWeather(at coordinate: CLLocationCoordinate2D, requestId: Int) async {
        defer {
            if currentRequestId == requestId {
                refreshTask = nil
            }
        }
        guard isForeground, !Task.isCancelled else { return }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "temperature_unit", value: "celsius")
        ]
        guard let url = components?.url else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled, isForeground, currentRequestId == requestId else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                markStale(reason: "서버 응답 오류")
                return
            }
            if let parsed = parseResponse(data: data) {
                reading = parsed
            } else {
                markStale(reason: "날씨 데이터 파싱 실패")
            }
        } catch {
            guard !Task.isCancelled, isForeground, currentRequestId == requestId else { return }
            // Keep last good weather on network/server failure and flag stale
            markStale(reason: "날씨 새로고침 실패")
        }
    }

    private func markStale(reason: String) {
        if let current = reading {
            reading = Reading(
                temperature: current.temperature,
                weatherCode: current.weatherCode,
                symbolName: current.symbolName,
                hourly: current.hourly,
                daily: current.daily,
                updatedAt: current.updatedAt,
                isStale: true,
                errorMessage: reason
            )
        }
    }

    private func parseResponse(data: Data) -> Reading? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let currentObj = json["current"] as? [String: Any],
              let temp = currentObj["temperature_2m"] as? Double,
              let code = currentObj["weather_code"] as? Int else {
            return nil
        }

        let isDay = (currentObj["is_day"] as? Int ?? 1) == 1
        let currentSymbol = Self.symbol(for: code, isDay: isDay)

        // Parse Hourly
        var hourlyList: [HourlyForecast] = []
        if let hourlyObj = json["hourly"] as? [String: Any],
           let times = hourlyObj["time"] as? [String],
           let temps = hourlyObj["temperature_2m"] as? [Double],
           let codes = hourlyObj["weather_code"] as? [Int] {
            let precips = hourlyObj["precipitation_probability"] as? [Any]

            let now = Date()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd'T'HH"
            let currentPrefix = formatter.string(from: now)

            var startIndex = 0
            for (idx, timeStr) in times.enumerated() {
                if timeStr.hasPrefix(currentPrefix) || timeStr >= currentPrefix {
                    startIndex = idx
                    break
                }
            }

            let endIndex = min(times.count, startIndex + 24)
            for i in startIndex..<endIndex {
                let timeStr = times[i]
                let hTemp = temps[i]
                let hCode = codes[i]
                var precipProb: Int? = nil
                if let precips = precips, i < precips.count, !(precips[i] is NSNull), let val = precips[i] as? Int {
                    precipProb = val
                }

                let hourPart = timeStr.components(separatedBy: "T").last?.components(separatedBy: ":").first ?? ""
                let hourInt = Int(hourPart) ?? (i % 24)
                let label = (i == startIndex) ? "지금" : "\(hourInt)시"
                let isDayHour = (6...18).contains(hourInt)

                hourlyList.append(HourlyForecast(
                    timeIso: timeStr,
                    timeLabel: label,
                    hour: hourInt,
                    temperature: hTemp,
                    weatherCode: hCode,
                    symbolName: Self.symbol(for: hCode, isDay: isDayHour),
                    precipitationProbability: precipProb
                ))
            }
        }

        // Parse Daily
        var dailyList: [DailyForecast] = []
        if let dailyObj = json["daily"] as? [String: Any],
           let times = dailyObj["time"] as? [String],
           let codes = dailyObj["weather_code"] as? [Int],
           let maxTemps = dailyObj["temperature_2m_max"] as? [Double],
           let minTemps = dailyObj["temperature_2m_min"] as? [Double] {
            let precips = dailyObj["precipitation_probability_max"] as? [Any]

            let isoFormatter = DateFormatter()
            isoFormatter.locale = Locale(identifier: "en_US_POSIX")
            isoFormatter.dateFormat = "yyyy-MM-dd"

            let dayFormatter = DateFormatter()
            dayFormatter.locale = Locale(identifier: "ko_KR")
            dayFormatter.dateFormat = "E"

            let count = min(7, times.count)
            for i in 0..<count {
                let dateStr = times[i]
                let dCode = codes[i]
                let maxT = maxTemps[i]
                let minT = minTemps[i]
                var precipProb: Int? = nil
                if let precips = precips, i < precips.count, !(precips[i] is NSNull), let val = precips[i] as? Int {
                    precipProb = val
                }

                let dayLabel: String
                if i == 0 {
                    dayLabel = "오늘"
                } else if let date = isoFormatter.date(from: dateStr) {
                    dayLabel = dayFormatter.string(from: date)
                } else {
                    dayLabel = "\(i)일후"
                }

                dailyList.append(DailyForecast(
                    dateIso: dateStr,
                    dayLabel: dayLabel,
                    weatherCode: dCode,
                    symbolName: Self.symbol(for: dCode, isDay: true),
                    maxTemp: maxT,
                    minTemp: minT,
                    precipitationProbability: precipProb
                ))
            }
        }

        return Reading(
            temperature: temp,
            weatherCode: code,
            symbolName: currentSymbol,
            hourly: hourlyList,
            daily: dailyList,
            updatedAt: Date(),
            isStale: false,
            errorMessage: nil
        )
    }

    static func symbol(for code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "snowflake"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}
