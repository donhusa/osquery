/*
 *  Copyright (c) 2014, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the BSD-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 */

#include <osquery/core.h>
#include <osquery/logger.h>
#include <osquery/tables.h>

#include "osquery/tables/system/darwin/certificates.h"

namespace osquery {
namespace tables {

const std::vector<std::string> kSystemKeychainPaths = {
    "/System/Library/Keychains", "/Library/Keychains",
};

const std::vector<std::string> kUserKeychainPaths = {
    "/Library/Keychains",
};

CFArrayRef CreateAuthorities() {
  CFMutableDictionaryRef query;
  query = CFDictionaryCreateMutable(NULL,
                                    0,
                                    &kCFTypeDictionaryKeyCallBacks,
                                    &kCFTypeDictionaryValueCallBacks);
  CFDictionaryAddValue(query, kSecClass, kSecClassCertificate);
  CFDictionaryAddValue(query, kSecReturnRef, kCFBooleanTrue);
  // This can be added to restrict results to x509v3
  // CFDictionaryAddValue(query, kSecAttrCertificateType, 0x03);
  // This can be added to restrict results to a Keychain
  // CFDictionaryAddValue(query, kSecMatchSearchList, CFArrayRef<KeychainRef>);
  CFDictionaryAddValue(query, kSecAttrCanVerify, kCFBooleanTrue);
  CFDictionaryAddValue(query, kSecMatchLimit, kSecMatchLimitAll);

  CFArrayRef keychain_certs;
  auto status = SecItemCopyMatching(query, (CFTypeRef *)&keychain_certs);
  CFRelease(query);

  if (status != errSecSuccess) {
    return nullptr;
  }

  return keychain_certs;
}

std::string getKeychainPath(const SecKeychainItemRef& item) {
  SecKeychainRef keychain = nullptr;
  std::string path;
  auto status = SecKeychainItemCopyKeychain(item, &keychain);
  if (keychain == nullptr) {
    // Unhandled error, cannot get the keychain reference from certificate.
    return path;
  }

  UInt32 path_size = 1024;
  char keychain_path[1024] = {0};
  status = SecKeychainGetPath(keychain, &path_size, keychain_path);
  if (path_size > 0 && keychain_path[0] != 0) {
    path = std::string(keychain_path);
  }

  CFRelease(keychain);
  return path;
}

void genCertificate(const SecCertificateRef& cert, QueryData& results) {
  Row r;

  // Iterate through each selected certificate property.
  for (const auto &detail : kCertificateProperties) {
    auto property = CreatePropertyFromCertificate(cert, detail.second.type);
    if (property == nullptr) {
      r[detail.first] = "";
      continue;
    }
    // Each property may be stored differently, apply a generator function.
    r[detail.first] = detail.second.generate(property);
    CFRelease(property);
  }

  // Fix missing basic constraints to indicate CA:false.
  if (r["ca"] == "") {
    r["ca"] = "0";
  }

  // Get the keychain for the certificate.
  r["path"] = getKeychainPath((SecKeychainItemRef)cert);

  // Hash is not a certificate property, calculate using raw data.
  r["sha1"] = genSHA1ForCertificate(cert);
  results.push_back(r);
}

QueryData genCerts(QueryContext &context) {
  QueryData results;

  // Keychains/certificate stores belonging to the OS.
  CFArrayRef certs = CreateAuthorities();
  // Must have returned an array of matching certificates.
  if (certs == nullptr || CFGetTypeID(certs) != CFArrayGetTypeID()) {
    VLOG(1) << "Could not find OS X Keychain";
    return results;
  }

  // Evaluate the certificate data, check for CA in Basic constraints.
  auto certificate_count = CFArrayGetCount(certs);
  for (CFIndex i = 0; i < certificate_count; i++) {
    auto cert = (SecCertificateRef)CFArrayGetValueAtIndex(certs, i);
    genCertificate(cert, results);
  }

  CFRelease(certs);
  return results;
}
}
}
