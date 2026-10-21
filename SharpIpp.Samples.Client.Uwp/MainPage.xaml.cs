using System;
using System.IO;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using SharpIpp;
using SharpIpp.Models.Requests;
using SharpIpp.Protocol.Models;

namespace SharpIpp.Samples.Client.Uwp
{
    public sealed partial class MainPage : Page
    {
        public MainPage()
        {
            this.InitializeComponent();
        }

        private async void RunTestButton_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                StatusText.Text = "Running IPP test...";

                var client = new SharpIppClient();
                var printerUri = new Uri("ipp://127.0.0.1:631/ipp/print");

                // Exercise GetPrinterAttributes with full attribute set
                var getAttributesRequest = new GetPrinterAttributesRequest
                {
                    OperationAttributes = new GetPrinterAttributesOperationAttributes()
                    {
                        PrinterUri = printerUri,
                        RequestedAttributes = new[]
                        {
                            "all",
                            "printer-description",
                            "job-template"
                        }
                    }
                };

                // Exercise PrintJobRequest model graph
                using (var dummyStream = new MemoryStream(new byte[] { 0x25, 0x50, 0x44, 0x46 }))
                {
                    var printJobRequest = new PrintJobRequest
                    {
                        Document = dummyStream,
                        OperationAttributes = new PrintJobOperationAttributes()
                        {
                            PrinterUri = printerUri,
                            DocumentName = "Sample UWP Document",
                            DocumentFormat = DocumentFormat.ApplicationPdf,
                            Compression = Compression.None,
                            DocumentNaturalLanguage = new NaturalLanguage("en-US"),
                            JobName = "UWP Test Job",
                            IppAttributeFidelity = false
                        },
                        JobTemplateAttributes = new JobTemplateAttributes()
                        {
                            Copies = 1,
                            MultipleDocumentHandling = MultipleDocumentHandling.SeparateDocumentsCollatedCopies,
                            Finishings = new[] { Finishings.None },
                            PageRanges = new[] { new SharpIpp.Protocol.Models.Range(1, 1) },
                            Sides = Sides.OneSided,
                            NumberUp = 1,
                            OrientationRequested = SharpIpp.Protocol.Models.Orientation.Portrait,
                            PrinterResolution = new Resolution(600, 600, ResolutionUnit.DotsPerInch),
                            PrintQuality = PrintQuality.Normal
                        }
                    };

                    // Exercise ValidateJobRequest
                    var validateRequest = new ValidateJobRequest
                    {
                        OperationAttributes = new ValidateJobOperationAttributes()
                        {
                            PrinterUri = printerUri
                        }
                    };

                    // Exercise IppValue and PrinterDescriptionAttributes instantiation
                    var attrs = new PrinterDescriptionAttributes
                    {
                        PrinterName = new StringWithLanguage("Test Printer"),
                        CharsetConfigured = new IppValue<string>("utf-8"),
                        QueuedJobCount = new IppValue<int>(0)
                    };

                    StatusText.Text = $"Initialized IPP models successfully: {attrs.PrinterName.Value}";
                }
            }
            catch (Exception ex)
            {
                StatusText.Text = $"Error: {ex.Message}";
            }
        }
    }
}
