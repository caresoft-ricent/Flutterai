import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final networkServiceProvider = Provider<NetworkService>((ref) {
  return NetworkService();
});

class NetworkService {
  const NetworkService();

  Future<bool> hasNetwork() async {
    final results = await Connectivity().checkConnectivity();
    return results.any((r) => r != ConnectivityResult.none);
  }
}
