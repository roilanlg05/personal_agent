import Foundation

/// GraphQL documents, request building and response interpretation for
/// .
///
/// REQUEST FIDELITY:
/// Replicates the exact GraphQL operations and parameter structures captured from the A to Z client,
/// while identifying explicitly and transparently as  via the User-Agent header.
enum AtoZGraphQL {
    static let findShiftsMoreQuery = #"""
query FindShiftsPageMore($timeRange: DateTimeRangeInput!, $filter: ShiftOpportunitiesFilter, $opportunityTypes: TypeFilter!, $canFetchPayBreakdown: Boolean = false, $canFetchInterestList: Boolean = false) {
  shiftOpportunities(timeRange: $timeRange, filter: $filter) {
    opportunities(opportunityTypes: $opportunityTypes) {
      id
      type
      ...OpportunityCardList_ShiftOpportunity
      ...FilteredShifts_ShiftOpportunity
      ...ShiftsPerDay_ShiftOpportunities
      ...ShiftFilters_ShiftOpportunity
      __typename
    }
    associateInformation {
      isFlexNodalEligible
      __typename
    }
    __typename
  }
}

fragment OpportunityCardList_ShiftOpportunity on ShiftOpportunity {
  ...OpportunityFlowModal_ShiftOpportunity
  ...OpportunityCard_ShiftOpportunity
  __typename
}

fragment OpportunityFlowModal_ShiftOpportunity on ShiftOpportunity {
  extendable
  acceptanceMode @include(if: $canFetchInterestList)
  interestStatus @include(if: $canFetchInterestList)
  interestListEnd @include(if: $canFetchInterestList)
  unavailability @include(if: $canFetchInterestList) {
    reasons
    __typename
  }
  ...UseAddOpportunityModalContentData_ShiftOpportunity
  ...UseShiftDetailsModalContentData_ShiftOpportunity
  __typename
}

fragment UseAddOpportunityModalContentData_ShiftOpportunity on ShiftOpportunity {
  id
  type
  dropDeadline
  penaltyStartTime
  extendable
  shift {
    id
    timeRange {
      start
      end
      __typename
    }
    __typename
  }
  incentivePay {
    payModifiers {
      applicableNetAmount {
        amount
        code
        __typename
      }
      category
      hourlyAdditionalCompensation {
        amount
        code
        __typename
      }
      name
      timeRange {
        start
        end
        __typename
      }
      __typename
    }
    __typename
  }
  eligibility {
    isEligible
    __typename
  }
  __typename
}

fragment UseShiftDetailsModalContentData_ShiftOpportunity on ShiftOpportunity {
  shift {
    ...UseShiftDetailsModalContentData_Shift
    __typename
  }
  skill
  skills {
    translationKey
    namespace
    defaultText
    __typename
  }
  ...UseShiftDetailsCardData_ShiftOpportunity
  ...UseShiftPayLinkData_ShiftOpportunity
  ...UseShiftPayBreakdownData_ShiftOpportunity
  __typename
}

fragment UseShiftDetailsModalContentData_Shift on Shift {
  site {
    specialInstructions
    __typename
  }
  ...UseShiftDetailsCardData_Shift
  __typename
}

fragment UseShiftDetailsCardData_Shift on Shift {
  id
  timeRange {
    start
    __typename
  }
  site {
    address
    __typename
  }
  ...UseShiftInfoData_Shift
  __typename
}

fragment UseShiftInfoData_Shift on Shift {
  timeRange {
    start
    end
    __typename
  }
  duration {
    value
    __typename
  }
  site {
    id
    address
    lineOfBusiness
    name
    city
    state
    __typename
  }
  __typename
}

fragment UseShiftDetailsCardData_ShiftOpportunity on ShiftOpportunity {
  shift {
    ...UseShiftDetailsCardData_Shift
    __typename
  }
  payBreakdown @include(if: $canFetchPayBreakdown) {
    ...UseShiftDetailsCardData_PayBreakdown
    __typename
  }
  ...UseShiftInfoData_ShiftOpportunity
  ...UseVtoAvailableCardData_ShiftOpportunity
  __typename
}

fragment UseShiftDetailsCardData_PayBreakdown on PayBreakdown {
  ...UseShiftInfoData_PayBreakdown
  __typename
}

fragment UseShiftInfoData_PayBreakdown on PayBreakdown {
  summary {
    duration {
      value
      __typename
    }
    __typename
  }
  __typename
}

fragment UseShiftInfoData_ShiftOpportunity on ShiftOpportunity {
  skill
  skills {
    translationKey
    namespace
    defaultText
    __typename
  }
  shift {
    ...UseShiftInfoData_Shift
    __typename
  }
  payBreakdown @include(if: $canFetchPayBreakdown) {
    ...UseShiftInfoData_PayBreakdown
    __typename
  }
  __typename
}

fragment UseVtoAvailableCardData_ShiftOpportunity on ShiftOpportunity {
  id
  shift {
    duration {
      value
      __typename
    }
    timeRange {
      start
      end
      __typename
    }
    __typename
  }
  ...useAcceptVto_ShiftOpportunity
  __typename
}

fragment useAcceptVto_ShiftOpportunity on ShiftOpportunity {
  id
  ...UseAcceptVtoSuccessData_ShiftOpportunity
  __typename
}

fragment UseAcceptVtoSuccessData_ShiftOpportunity on ShiftOpportunity {
  shift {
    id
    timeRange {
      start
      end
      __typename
    }
    duration {
      value
      __typename
    }
    __typename
  }
  __typename
}

fragment UseShiftPayLinkData_ShiftOpportunity on ShiftOpportunity {
  incentivePay {
    ...UseShiftPayLinkData_IncentivePay
    __typename
  }
  __typename
}

fragment UseShiftPayLinkData_IncentivePay on IncentivePay {
  netPayModifier {
    code
    amount
    __typename
  }
  payModifiers {
    category
    applicableNetAmount {
      code
      amount
      __typename
    }
    hourlyAdditionalCompensation {
      code
      amount
      __typename
    }
    __typename
  }
  __typename
}

fragment UseShiftPayBreakdownData_ShiftOpportunity on ShiftOpportunity {
  payBreakdown @include(if: $canFetchPayBreakdown) {
    ...UseShiftPayBreakdownData_PayBreakdown
    __typename
  }
  __typename
}

fragment UseShiftPayBreakdownData_PayBreakdown on PayBreakdown {
  base {
    ...UseShiftPayBreakdownData_BreakdownRange
    __typename
  }
  shiftDifferential {
    ...UseShiftPayBreakdownData_BreakdownRange
    __typename
  }
  premiums {
    ...UseShiftPayBreakdownData_BreakdownRange
    __typename
  }
  summary {
    ...UseShiftPayBreakdownData_BreakdownSummary
    __typename
  }
  __typename
}

fragment UseShiftPayBreakdownData_BreakdownRange on BreakdownRange {
  category
  hourlyCompensation {
    ...UseShiftPayBreakdownData_Currency
    __typename
  }
  durationRange {
    min {
      value
      __typename
    }
    max {
      value
      __typename
    }
    __typename
  }
  totalCompensationRange {
    min {
      ...UseShiftPayBreakdownData_Currency
      __typename
    }
    max {
      ...UseShiftPayBreakdownData_Currency
      __typename
    }
    __typename
  }
  __typename
}

fragment UseShiftPayBreakdownData_Currency on Currency {
  amount
  code
  __typename
}

fragment UseShiftPayBreakdownData_BreakdownSummary on BreakdownSummary {
  totalShiftPayRange {
    min {
      ...UseShiftPayBreakdownData_Currency
      __typename
    }
    max {
      ...UseShiftPayBreakdownData_Currency
      __typename
    }
    __typename
  }
  duration {
    value
    __typename
  }
  hourlyShiftRateRange {
    min {
      ...UseShiftPayBreakdownData_Currency
      __typename
    }
    max {
      ...UseShiftPayBreakdownData_Currency
      __typename
    }
    __typename
  }
  __typename
}

fragment OpportunityCard_ShiftOpportunity on ShiftOpportunity {
  type
  dropDeadline
  penaltyStartTime
  extendable
  acceptanceMode @include(if: $canFetchInterestList)
  interestStatus @include(if: $canFetchInterestList)
  interestListEnd @include(if: $canFetchInterestList)
  eligibility {
    isEligible
    unclaimableReasonCodes
    __typename
  }
  unavailability @include(if: $canFetchInterestList) {
    reasons
    __typename
  }
  shift {
    id
    site {
      isAssociateHomeSite
      __typename
    }
    ...UseShiftInfoData_Shift
    __typename
  }
  incentivePay {
    payModifiers {
      applicableNetAmount {
        amount
        code
        __typename
      }
      category
      hourlyAdditionalCompensation {
        amount
        code
        __typename
      }
      name
      timeRange {
        start
        end
        __typename
      }
      __typename
    }
    __typename
  }
  ...UsePayLabelData_ShiftOpportunity
  ...UseShiftInfoData_ShiftOpportunity
  __typename
}

fragment UsePayLabelData_ShiftOpportunity on ShiftOpportunity {
  shift {
    ...UsePayLabelData_Shift
    __typename
  }
  incentivePay {
    ...UsePayLabelData_IncentivePay
    __typename
  }
  payBreakdown @include(if: $canFetchPayBreakdown) {
    ...UsePayLabelData_PayBreakdown
    __typename
  }
  __typename
}

fragment UsePayLabelData_Shift on Shift {
  timeRange {
    start
    end
    __typename
  }
  duration {
    value
    __typename
  }
  __typename
}

fragment UsePayLabelData_IncentivePay on IncentivePay {
  netPayModifier {
    amount
    code
    __typename
  }
  payModifiers {
    applicableNetAmount {
      code
      amount
      __typename
    }
    category
    __typename
  }
  __typename
}

fragment UsePayLabelData_PayBreakdown on PayBreakdown {
  summary {
    hourlyShiftRateRange {
      min {
        amount
        code
        __typename
      }
      max {
        amount
        code
        __typename
      }
      __typename
    }
    __typename
  }
  premiums {
    category
    __typename
  }
  __typename
}

fragment FilteredShifts_ShiftOpportunity on ShiftOpportunity {
  type
  shift {
    site {
      id
      name
      __typename
    }
    timeRange {
      start
      end
      __typename
    }
    __typename
  }
  eligibility {
    isEligible
    unclaimableReasonCodes
    __typename
  }
  acceptanceMode @include(if: $canFetchInterestList)
  interestStatus @include(if: $canFetchInterestList)
  unavailability @include(if: $canFetchInterestList) {
    reasons
    __typename
  }
  incentivePay {
    netPayModifier {
      code
      __typename
    }
    payModifiers {
      name
      __typename
    }
    __typename
  }
  payBreakdown @include(if: $canFetchPayBreakdown) {
    premiums {
      category
      __typename
    }
    __typename
  }
  skill
  skills {
    translationKey
    namespace
    defaultText
    __typename
  }
  __typename
}

fragment ShiftsPerDay_ShiftOpportunities on ShiftOpportunity {
  ...ShiftFlowModal_ShiftOpportunities
  ...ShiftCard_ShiftOpportunities
  __typename
}

fragment ShiftFlowModal_ShiftOpportunities on ShiftOpportunity {
  id
  type
  addDeadline
  dropDeadline
  shift {
    ...ShiftFlowModal_Shift
    __typename
  }
  ...UseDropShiftModalContentData_ShiftOpportunity
  ...UseShiftDetailsModalBannersData_ShiftOpportunity
  ...UseShiftDetailsModalContentData_ShiftOpportunities
  ...UseSelectVtoModalContentData_ShiftOpportunity
  __typename
}

fragment ShiftFlowModal_Shift on Shift {
  id
  timeRange {
    start
    end
    __typename
  }
  __typename
}

fragment UseDropShiftModalContentData_ShiftOpportunity on ShiftOpportunity {
  id
  type
  penaltyStartTime
  addDeadline
  dropDeadline
  shift {
    id
    __typename
  }
  __typename
}

fragment UseShiftDetailsModalBannersData_ShiftOpportunity on ShiftOpportunity {
  ...UseShiftDetailsModalScheduledBannersData_ShiftOpportunity
  __typename
}

fragment UseShiftDetailsModalScheduledBannersData_ShiftOpportunity on ShiftOpportunity {
  id
  type
  extendable
  penaltyStartTime
  shift {
    ...UseShiftDetailsModalScheduledBannersData_Shift
    __typename
  }
  ...UseScheduledShiftStatus_ShiftOpportunity
  __typename
}

fragment UseShiftDetailsModalScheduledBannersData_Shift on Shift {
  id
  timeRange {
    start
    end
    __typename
  }
  __typename
}

fragment UseScheduledShiftStatus_ShiftOpportunity on ShiftOpportunity {
  id
  type
  addDeadline
  dropDeadline
  extendable
  shift {
    ...UseScheduledShiftStatus_Shift
    __typename
  }
  __typename
}

fragment UseScheduledShiftStatus_Shift on Shift {
  id
  timeRange {
    start
    end
    __typename
  }
  __typename
}

fragment UseShiftDetailsModalContentData_ShiftOpportunities on ShiftOpportunity {
  ...UseShiftDetailsModalContentData_ShiftOpportunity
  ...UseShiftDetailsCardData_ShiftOpportunities
  __typename
}

fragment UseShiftDetailsCardData_ShiftOpportunities on ShiftOpportunity {
  ...UseShiftDetailsCardData_ShiftOpportunity
  ...UseVtoAvailableCardData_ShiftOpportunity
  __typename
}

fragment UseSelectVtoModalContentData_ShiftOpportunity on ShiftOpportunity {
  id
  shift {
    duration {
      value
      __typename
    }
    timeRange {
      start
      end
      __typename
    }
    __typename
  }
  type
  ...useAcceptVto_ShiftOpportunity
  __typename
}

fragment ShiftCard_ShiftOpportunities on ShiftOpportunity {
  id
  type
  penaltyStartTime
  shift {
    id
    duration {
      value
      __typename
    }
    timeRange {
      start
      end
      __typename
    }
    ...ShiftCard_Shift
    __typename
  }
  eligibility {
    isEligible
    __typename
  }
  unavailability {
    reasons
    __typename
  }
  ...UseShiftCardStatusData_ShiftOpportunity
  ...UseShiftInfoData_ShiftOpportunity
  __typename
}

fragment ShiftCard_Shift on Shift {
  id
  timeRange {
    start
    end
    __typename
  }
  site {
    isAssociateHomeSite
    __typename
  }
  __typename
}

fragment UseShiftCardStatusData_ShiftOpportunity on ShiftOpportunity {
  shift {
    ...UseShiftCardScheduledStatusData_Shift
    __typename
  }
  ...UseShiftCardScheduledStatusData_ShiftOpportunity
  __typename
}

fragment UseShiftCardScheduledStatusData_Shift on Shift {
  id
  duration {
    value
    __typename
  }
  timeRange {
    start
    end
    __typename
  }
  __typename
}

fragment UseShiftCardScheduledStatusData_ShiftOpportunity on ShiftOpportunity {
  extendable
  shift {
    ...UseShiftCardScheduledStatusData_Shift
    __typename
  }
  ...UseScheduledShiftStatus_ShiftOpportunity
  __typename
}

fragment ShiftFilters_ShiftOpportunity on ShiftOpportunity {
  shift {
    site {
      id
      name
      __typename
    }
    __typename
  }
  skill
  skills {
    translationKey
    namespace
    defaultText
    __typename
  }
  __typename
}
"""#

    static let scheduleQuery = #"""
query GemmaScheduleCheck($timeRange: DateTimeRangeInput!) {
  schedule(timeRange: $timeRange) {
    scheduleShifts {
      shift {
        id
        timeRange {
          start
          end
          __typename
        }
        __typename
      }
      __typename
    }
    __typename
  }
}
"""#

    static let addShiftMutation = #"""
mutation AddShift($shiftOpportunityId: AddShiftInput!) {
  addShift(input: $shiftOpportunityId)
}
"""#

    static let dropShiftMutation = #"""
mutation DropShift($shiftOpportunityId: DropShiftInput!) {
  dropShift(input: $shiftOpportunityId)
}
"""#

    // MARK: - Variables Generation

    static func findShiftsVariables(start: Date, end: Date) -> [String: Any] {
        [
            "canFetchPayBreakdown": true,
            "canFetchInterestList": false,
            "filter": [
                "includeIneligible": true,
                "unavailableReasonsToInclude": [
                    "AssociateAccepted",
                    "ShiftOpportunityCapacityMet",
                    "ShiftOpportunityExpired"
                ]
            ],
            "timeRange": [
                "start": isoString(start),
                "end": isoString(end)
            ],
            "opportunityTypes": [
                "types": ["DROP", "VOLUNTARY_TIME_OFF", "ADD", "VOLUNTARY_EXTRA_TIME"]
            ]
        ]
    }

    static func addShiftVariables(opportunityId: String) -> [String: Any] {
        [
            "shiftOpportunityId": [
                "shiftOpportunityId": opportunityId
            ]
        ]
    }

    static func dropShiftVariables(opportunityId: String) -> [String: Any] {
        [
            "shiftOpportunityId": [
                "shiftOpportunityId": opportunityId
            ]
        ]
    }

    // MARK: - Dates

    static func isoString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: - HTTP Request Building

    static func makeRequest(operationName: String,
                            query: String,
                            variables: [String: Any],
                            session: AtoZSession) throws -> URLRequest {
        var comps = URLComponents(url: AtoZConstants.graphQLURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "employeeId", value: session.employeeId)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.httpShouldHandleCookies = false
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        // Mandatory Agent Identification (Guidelines §2)
        req.setValue(AtoZConstants.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("https://atoz.amazon.work", forHTTPHeaderField: "Origin")
        req.setValue("https://atoz.amazon.work/", forHTTPHeaderField: "Referer")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        req.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")
        req.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        req.setValue(AtoZConstants.clientIdHeader, forHTTPHeaderField: "x-atoz-client-id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "x-atoz-client-request-id")
        req.setValue(session.cookie, forHTTPHeaderField: "Cookie")
        if let rawToken = AtoZSessionParser.extractRawToken(from: session.cookie) {
            req.setValue("Bearer \(rawToken)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "operationName": operationName,
            "variables": variables,
            "query": query
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Response Classification

    static func classifyHTTP(status: Int, headers: [AnyHashable: Any], finalURL: URL?, body: Data) -> AtoZFailure? {
        func header(_ name: String) -> String? {
            for (k, v) in headers where (k as? String)?.lowercased() == name { return v as? String }
            return nil
        }
        let contentType = header("content-type")?.lowercased() ?? ""
        let text = String(data: body.prefix(4096), encoding: .utf8)?.lowercased() ?? ""
        let isChallenge = header("cf-mitigated")?.lowercased() == "challenge"
            || text.contains("challenge-platform") || text.contains("cf-chl") || text.contains("captcha")
        let host = finalURL?.host?.lowercased() ?? ""
        let isLogin = host.hasPrefix("atoz-login.") || host.contains("idp.federate") || host.contains("idprism-auth")
            || (finalURL?.path.lowercased().hasPrefix("/login") ?? false)

        // Safe diagnostic: status + redirect host/path only (query stripped, no secrets).
        var diag = "HTTP \(status)"
        if let loc = header("location"), let u = URL(string: loc, relativeTo: finalURL) {
            diag += " → \(u.host ?? "")\(u.path)"
        }
        if !contentType.isEmpty { diag += ", \(contentType.split(separator: ";").first ?? "")" }

        if isChallenge { AtoZDiagnostics.record(diag); return .accessLimited("verificación anti-bot / CAPTCHA") }
        switch status {
        case 401: AtoZDiagnostics.record(diag); return .sessionExpired
        case 403: AtoZDiagnostics.record(diag); return .accessDenied
        case 429: AtoZDiagnostics.record(diag); return .accessLimited("demasiadas solicitudes (HTTP 429)")
        case 300...399:
            // Redirects are not followed; a redirect from the API means the session was rejected.
            AtoZDiagnostics.record(diag)
            return .sessionExpired
        case 500...599: AtoZDiagnostics.record(diag); return .serverError(status)
        case 200...299: break
        default: AtoZDiagnostics.record(diag); return .unknown("HTTP \(status)")
        }
        if isLogin { AtoZDiagnostics.record(diag + " (login)"); return .sessionExpired }
        if !contentType.contains("json") {
            AtoZDiagnostics.record(diag)
            return text.contains("login") || text.contains("sign in") ? .sessionExpired : .unknown("respuesta no JSON")
        }
        return nil
    }

    static func classifyGraphQLErrors(_ errors: [[String: Any]]) -> AtoZFailure {
        let parts: [String] = errors.map { e in
            let ext = e["extensions"] as? [String: Any]
            return [ext?["code"] as? String, ext?["errorType"] as? String, e["errorType"] as? String, e["message"] as? String]
                .compactMap { $0 }.joined(separator: " ")
        }
        let blob = parts.joined(separator: " | ").lowercased()
        AtoZDiagnostics.record("GraphQL: " + String((parts.first ?? "").prefix(100)))
        func has(_ keys: [String]) -> Bool { keys.contains { blob.contains($0) } }
        if has(["unauthenticated", "not authenticated", "unauthorized", "session expired", "token expired"]) { return .sessionExpired }
        if has(["throttl", "rate limit", "too many requests", "toomanyrequests"]) { return .accessLimited("límite de solicitudes") }
        if has(["forbidden", "accessdenied", "access denied"]) { return .accessDenied }
        if has(["capacity", "expired", "no longer", "not available", "unavailable", "not found", "already"]) { return .shiftUnavailable }
        if has(["conflict", "overlap", "exceed", "maximum", "limit", "hours", "eligib", "rest period"]) { return .scheduleConflict }
        let first = parts.first ?? "error GraphQL"
        return .unknown(String(first.prefix(120)))
    }

    // MARK: - Parsing

    static func parseOpportunities(_ data: [String: Any]) -> [AtoZShiftOpportunity]? {
        guard let so = data["shiftOpportunities"] as? [String: Any],
              let list = so["opportunities"] as? [[String: Any]] else { return nil }
        return list.compactMap { o in
            guard let id = o["id"] as? String, !id.isEmpty,
                  let shift = o["shift"] as? [String: Any],
                  let tr = shift["timeRange"] as? [String: Any],
                  let s = parseDate(tr["start"] as? String), let e = parseDate(tr["end"] as? String) else { return nil }
            let el = o["eligibility"] as? [String: Any]
            return AtoZShiftOpportunity(
                id: id, type: (o["type"] as? String) ?? "",
                start: s, end: e,
                isEligible: (el?["isEligible"] as? Bool) ?? false,
                unclaimableReasonCodes: (el?["unclaimableReasonCodes"] as? [String]) ?? [])
        }
    }

    struct ScheduledShift: Equatable {
        let id: String?
        let start: Date
        let end: Date
    }

    static func parseSchedule(_ data: [String: Any]) -> [ScheduledShift]? {
        guard let sch = data["schedule"] as? [String: Any],
              let list = sch["scheduleShifts"] as? [[String: Any]] else { return nil }
        return list.compactMap { ss in
            guard let shift = ss["shift"] as? [String: Any],
                  let tr = shift["timeRange"] as? [String: Any],
                  let s = parseDate(tr["start"] as? String), let e = parseDate(tr["end"] as? String) else { return nil }
            return ScheduledShift(id: shift["id"] as? String, start: s, end: e)
        }
    }
}
