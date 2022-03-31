package main

import (
	// "log"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

var verifyOpts x509.VerifyOptions
var currentTime time.Time
var onesecond_more time.Duration
var now = time.Now()
var rejectExpired = false

func init() {
	var err error
	onesecond_more, err = time.ParseDuration("1s")
	if err != nil { // but this should never happen
		panic(err)
	}
}

// This function is a modified version of verifyServerCertificate, which can be found at
// https://github.com/golang/go/blob/go1.15/src/crypto/tls/handshake_client.go#L824
// (from here on, this will be called "upstream")
func verifyButAcceptExpired(rawCerts [][]byte, verifiedChains [][]*x509.Certificate) error {
	// Just like upstream, parse and collect certificates
	certs := make([]*x509.Certificate, len(rawCerts))
	for i, asn1Data := range rawCerts {
		cert, err := x509.ParseCertificate(asn1Data)
		if err != nil {
			return errors.New("tls: failed to parse certificate from server: " + err.Error())
		}
		certs[i] = cert
	}

	// In upstream, we're creating the x509.VerifyOptions object right now.
	// here, we're using a global which is created in main. That's because we wouldn't have access to Conn
	// data otherwise.
	// Still, the object ends up having the same values
	for _, cert := range certs[1:] {
		verifyOpts.Intermediates.AddCert(cert)
	}

	// Before going on, let's check that the leaf certificate is for the valid hostname
	// XXX: does this really add anything, that the subsequent certs[0].Verify() wouldn't have noticed?
	if err := certs[0].VerifyHostname(verifyOpts.DNSName); err != nil {
		return err
	}

	if !rejectExpired || certs[0].NotBefore.After(currentTime) {
		// that's the real change: we're pretending that the time of verification is after the
		// not-before field of the leaf certificate.
		verifyOpts.CurrentTime = certs[0].NotBefore.Add(onesecond_more)
	} else {
		verifyOpts.CurrentTime = currentTime
	}

	// Just like upstream: perform verification
	if _, err := certs[0].Verify(verifyOpts); err != nil {
		return err
	}

	// Just like upstream: check that the public key type is modern enough
	switch certs[0].PublicKey.(type) {
	case *rsa.PublicKey, *ecdsa.PublicKey, ed25519.PublicKey:
		break
	default:
		return fmt.Errorf("tls: server's certificate contains an unsupported type of public key: %T", certs[0].PublicKey)
	}

	// upstream has other if statements after this. They don't apply to us
	// because they run code for opt-in features that we don't enable.

	return nil
}

// XXX: emulate htpdate --proxy, that is curl --socks5-hostname

func main() {
	var err error
	flag.BoolVar(&rejectExpired, "reject-expired", false, "If set, only future certificates are accepted.")
	user_agent := flag.String("user-agent", "", "Set user-agent header.")
	timeout := flag.Duration("timeout", 30*time.Second, "Request timeout.")
	proxy := flag.String("proxy", "", "Set a proxy for the request. socks5:// syntax supported")

	output_headers := flag.String("output", "", "Write date header to FILE. If omitted, date is printed on stdout.")

	currentTimeS := flag.String("current-time", "", "simulate a different current-time. Debug only!")
	flag.Parse()
	if len(*currentTimeS) > 0 {
		currentTime, err = time.Parse("2006-01-02", *currentTimeS)
		if err != nil {
			fmt.Fprintln(os.Stderr, "Invalid format for current-time:", err.Error())
			os.Exit(2)
		}
	} else {
		currentTime = time.Now()
	}

	urlString := flag.Args()[0]
	urlRequest, err := url.Parse(urlString)
	if err != nil {
		fmt.Fprintln(os.Stderr, "invlid url")
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	hostname := urlRequest.Hostname()

	config := tls.Config{VerifyPeerCertificate: verifyButAcceptExpired, InsecureSkipVerify: true, MinVersion: tls.VersionTLS10}
	transCfg := &http.Transport{
		TLSClientConfig: &config,
		Proxy: func(req *http.Request) (*url.URL, error) {
			if *proxy == "" {
				return nil, nil
			}
			return url.Parse(*proxy)
		},
	}
	verifyOpts = x509.VerifyOptions{
		Roots:         config.RootCAs,
		DNSName:       hostname,
		Intermediates: x509.NewCertPool(),
	}
	client := &http.Client{Transport: transCfg, Timeout: *timeout, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	}}

	request, err := http.NewRequest("HEAD", urlString, nil)
	if *user_agent != "" {
		request.Header.Set("User-Agent", *user_agent)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error preparing the request")
		os.Exit(1)
	}
	response, err := client.Do(request)

	if err != nil {
		fmt.Fprintln(os.Stderr, "Error while performing HTTP request:", err)
		os.Exit(1)
	}

	if *output_headers != "" {

		// don't output headers we don't care about
		exclude_headers := make(map[string]bool)
		for key := range response.Header {
			if strings.ToLower(key) != "date" {
				exclude_headers[key] = true
			}
		}

		buf, err := os.OpenFile(*output_headers, os.O_WRONLY|os.O_CREATE, 0600)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}

		err = response.Header.WriteSubset(buf, exclude_headers)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Exit(0)
	} else {
		fmt.Println(response.Header.Get("date"))
	}

	os.Exit(0)
}
