class ConnectionFailure implements Exception {
  ConnectionFailure(this.message, {this.permanent = false});
  final String message;
  final bool permanent;
  @override
  String toString() => message;
}

class SessionUnavailable extends ConnectionFailure {
  SessionUnavailable([super.message = 'This session is no longer available.'])
    : super(permanent: true);
}

class DeliveryUncertain implements Exception {
  DeliveryUncertain([
    this.message = 'Delivery could not be confirmed. Your message may have arrived. Check the terminal before sending again.',
  ]);
  final String message;
  @override
  String toString() => message;
}

class SessionActionUncertain implements Exception {
  const SessionActionUncertain();
  @override
  String toString() =>
      'This action may have completed. Check the sessions on this computer before trying another action.';
}
